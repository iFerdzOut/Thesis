// ═══════════════════════════════════════════════════════════════════════════════
// SMISHING DETECTION PIPELINE  —  SINGLE-FILE ENTRY POINT
//
// This file is the ONLY file the rest of the app needs to import for all
// smishing detection. It contains the full 5-stage pipeline end-to-end:
//
//   Public API (SmishingPipelineService):
//     • quickScan(message)         — fast pre-check (allowlist / no-URL)
//     • deepScan(message)          — full 5-stage DistilBERT pipeline
//     • enqueue(message, …)        — background FIFO scan queue
//
//   Stage 1 — Message Buffer        (MessageBufferStage)
//   Stage 2 — Heuristic Layer       (AllowlistFilterStage)
//   Stage 3 — DistilBERT Pipeline   (DeepLearningPipelineStage)
//              DistilBERT Model      (DistilBertModel  — WordPiece tokenizer)
//              Isolate Runner        (DistilBertIsolateRunner)
//   Stage 4 — Probability Calc      (ProbabilityCalculationStage + SoftmaxScorer)
//   Stage 5 — Output Router         (OutputRouterStage)
//
//   Pipeline I/O contracts (embedded — import this file to use them):
//     ScreenedMessageModel          — pipeline input  (raw incoming message)
//     DetectionDecision             — verdict string constants
//     DetectionResultModel          — pipeline output (full scan result)
//
//   Support:
//     URL utilities                 (UrlExtractor, UrlDefanger)
//     Domain allowlist              (DomainAllowlist, StaticDomainAllowlist)
//     Pipeline data models          (Stage1–4Result)
//     SQLite domain row model       (TrustedDomainModel)
// ═══════════════════════════════════════════════════════════════════════════════

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../models/safety_status.dart';
import '../services/screening/local_detection_repository.dart';
import '../services/system/native_channel_router.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PIPELINE I/O DATA CONTRACTS
//
// ScreenedMessageModel  — pipeline input  (raw incoming message)
// DetectionDecision     — verdict constants produced by Stage 5
// DetectionResultModel  — pipeline output (full scan result)
// ─────────────────────────────────────────────────────────────────────────────

/// Raw message record passed into the pipeline.
///
/// It keeps SMS/provider metadata beside the message body so scan results can
/// be written back to the right local message row after classification.
class ScreenedMessageModel {
  final String source;
  final String sender;
  final String? peer;
  final String body;
  final int timestampMs;
  final String messageKey;
  final int? providerId;
  final String? providerThreadId;
  final int? simSlot;
  final int? subscriptionId;

  const ScreenedMessageModel({
    required this.source,
    required this.sender,
    required this.peer,
    required this.body,
    required this.timestampMs,
    required this.messageKey,
    required this.providerId,
    required this.providerThreadId,
    required this.simSlot,
    required this.subscriptionId,
  });

  /// Serializes the message for database storage, queues, or platform bridges.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'source': source,
      'sender': sender,
      'peer': peer,
      'body': body,
      'timestampMs': timestampMs,
      'messageKey': messageKey,
      'providerId': providerId,
      'providerThreadId': providerThreadId,
      'simSlot': simSlot,
      'subscriptionId': subscriptionId,
    };
  }

  /// Rebuilds a message from loosely typed storage or platform-channel data.
  factory ScreenedMessageModel.fromMap(Map<String, dynamic> map) {
    return ScreenedMessageModel(
      source: map['source']?.toString() ?? 'sms',
      sender: map['sender']?.toString() ?? '',
      peer: map['peer']?.toString(),
      body: map['body']?.toString() ?? '',
      timestampMs: (map['timestampMs'] as num?)?.toInt() ??
          (map['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      messageKey: map['messageKey']?.toString() ?? '',
      providerId: (map['providerId'] as num?)?.toInt(),
      providerThreadId:
          map['providerThreadId']?.toString() ?? map['threadId']?.toString(),
      simSlot: (map['simSlot'] as num?)?.toInt(),
      subscriptionId: (map['subscriptionId'] as num?)?.toInt(),
    );
  }

  /// Creates a copy while replacing only the fields supplied by the caller.
  ScreenedMessageModel copyWith({
    String? source,
    String? sender,
    String? peer,
    String? body,
    int? timestampMs,
    String? messageKey,
    int? providerId,
    String? providerThreadId,
    int? simSlot,
    int? subscriptionId,
  }) {
    return ScreenedMessageModel(
      source: source ?? this.source,
      sender: sender ?? this.sender,
      peer: peer ?? this.peer,
      body: body ?? this.body,
      timestampMs: timestampMs ?? this.timestampMs,
      messageKey: messageKey ?? this.messageKey,
      providerId: providerId ?? this.providerId,
      providerThreadId: providerThreadId ?? this.providerThreadId,
      simSlot: simSlot ?? this.simSlot,
      subscriptionId: subscriptionId ?? this.subscriptionId,
    );
  }
}

/// Stable string constants used by storage and UI code to explain routing.
class DetectionDecision {
  static const String allowTrusted = 'allow_trusted';
  static const String allowLowRisk = 'allow_low_risk';
  static const String quarantineHighRisk = 'quarantine_high_risk';
  static const String noUrlAllow = 'no_url_allow';
  static const String modelErrorFallback = 'model_error_fallback';
  static const String manualReview = 'manual_review';

  static const Set<String> values = <String>{
    allowTrusted,
    allowLowRisk,
    quarantineHighRisk,
    noUrlAllow,
    modelErrorFallback,
    manualReview,
  };
}

/// Complete scan result emitted by the pipeline.
///
/// Contains both machine-readable fields for storage/routing and human-readable
/// reasons for inbox/quarantine screens.
class DetectionResultModel {
  final String messageKey;
  final bool hasUrl;
  final List<String> extractedUrls;
  final String? primaryUrl;
  final String? primaryDomain;
  final bool trustedMatch;
  final bool mlInvoked;
  final List<double> rawLogits;
  final double riskScore;
  final double quarantineThreshold;
  final String decision;
  final String reason;
  final List<String> explanations;
  final bool needsRescan;
  final double heuristicScore;
  final double? modelScore;
  final String riskLevel;
  final String detectionSource;
  final String pipelineStage;

  const DetectionResultModel({
    required this.messageKey,
    required this.hasUrl,
    required this.extractedUrls,
    required this.primaryUrl,
    required this.primaryDomain,
    required this.trustedMatch,
    required this.mlInvoked,
    required this.rawLogits,
    required this.riskScore,
    required this.quarantineThreshold,
    required this.decision,
    required this.reason,
    required this.explanations,
    required this.needsRescan,
    required this.heuristicScore,
    required this.modelScore,
    required this.riskLevel,
    required this.detectionSource,
    required this.pipelineStage,
  });

  /// True when the score meets the active quarantine threshold.
  bool get isSuspicious => riskScore >= quarantineThreshold;

  /// True when the message should be moved to quarantine rather than inbox.
  bool get shouldQuarantine =>
      decision == DetectionDecision.quarantineHighRisk ||
      (decision != DetectionDecision.modelErrorFallback &&
          riskScore >= quarantineThreshold);

  /// Serializes the full result for persistence and debugging.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'messageKey': messageKey,
      'hasUrl': hasUrl,
      'extractedUrls': extractedUrls,
      'primaryUrl': primaryUrl,
      'primaryDomain': primaryDomain,
      'trustedMatch': trustedMatch,
      'mlInvoked': mlInvoked,
      'rawLogits': rawLogits,
      'riskScore': riskScore,
      'quarantineThreshold': quarantineThreshold,
      'decision': decision,
      'reason': reason,
      'explanations': explanations,
      'needsRescan': needsRescan,
      'heuristicScore': heuristicScore,
      'modelScore': modelScore,
      'riskLevel': riskLevel,
      'detectionSource': detectionSource,
      'pipelineStage': pipelineStage,
      'isSuspicious': isSuspicious,
      'shouldQuarantine': shouldQuarantine,
    };
  }

  /// Returns the smaller metadata shape attached to SMS rows in the app.
  Map<String, dynamic> toSmsMetadataMap() {
    return <String, dynamic>{
      'messageKey': messageKey,
      'isSuspicious': isSuspicious,
      'riskScore': riskScore,
      'riskLevel': riskLevel,
      'detectionReasons': explanations,
      'modelScore': modelScore,
      'heuristicScore': heuristicScore,
      'detectionSource': detectionSource,
      'pipelineStage': pipelineStage,
      'detectionDecision': decision,
      'primaryUrl': primaryUrl,
      'primaryDomain': primaryDomain,
      'extractedUrls': extractedUrls,
      'needsRescan': needsRescan,
    };
  }

  /// Rehydrates a stored result while applying safe defaults for old rows.
  factory DetectionResultModel.fromMap(Map<String, dynamic> map) {
    final decision =
        map['decision']?.toString() ?? DetectionDecision.noUrlAllow;
    return DetectionResultModel(
      messageKey: map['messageKey']?.toString() ?? '',
      hasUrl: map['hasUrl'] == true,
      extractedUrls:
          (map['extractedUrls'] as List<dynamic>? ?? const <dynamic>[])
              .map((dynamic item) => item.toString())
              .where((String item) => item.trim().isNotEmpty)
              .toList(growable: false),
      primaryUrl: map['primaryUrl']?.toString(),
      primaryDomain: map['primaryDomain']?.toString(),
      trustedMatch: map['trustedMatch'] == true,
      mlInvoked: map['mlInvoked'] == true,
      rawLogits: (map['rawLogits'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic item) => (item as num).toDouble())
          .toList(growable: false),
      riskScore: ((map['riskScore'] as num?) ?? 0).toDouble(),
      quarantineThreshold:
          ((map['quarantineThreshold'] as num?) ?? 0.72).toDouble(),
      decision: DetectionDecision.values.contains(decision)
          ? decision
          : DetectionDecision.noUrlAllow,
      reason: map['reason']?.toString() ?? '',
      explanations: (map['explanations'] as List<dynamic>? ?? const <dynamic>[])
          .map((dynamic item) => item.toString())
          .where((String item) => item.trim().isNotEmpty)
          .toList(growable: false),
      needsRescan: map['needsRescan'] == true,
      heuristicScore: ((map['heuristicScore'] as num?) ?? 0).toDouble(),
      modelScore: (map['modelScore'] as num?)?.toDouble(),
      riskLevel: map['riskLevel']?.toString() ?? 'safe',
      detectionSource:
          map['detectionSource']?.toString() ?? 'heuristic_text_fallback',
      pipelineStage: map['pipelineStage']?.toString() ?? 'heuristic_fallback',
    );
  }

  /// Creates a modified copy without losing the original scan details.
  DetectionResultModel copyWith({
    String? messageKey,
    bool? hasUrl,
    List<String>? extractedUrls,
    String? primaryUrl,
    String? primaryDomain,
    bool? trustedMatch,
    bool? mlInvoked,
    List<double>? rawLogits,
    double? riskScore,
    double? quarantineThreshold,
    String? decision,
    String? reason,
    List<String>? explanations,
    bool? needsRescan,
    double? heuristicScore,
    double? modelScore,
    String? riskLevel,
    String? detectionSource,
    String? pipelineStage,
  }) {
    return DetectionResultModel(
      messageKey: messageKey ?? this.messageKey,
      hasUrl: hasUrl ?? this.hasUrl,
      extractedUrls: extractedUrls ?? this.extractedUrls,
      primaryUrl: primaryUrl ?? this.primaryUrl,
      primaryDomain: primaryDomain ?? this.primaryDomain,
      trustedMatch: trustedMatch ?? this.trustedMatch,
      mlInvoked: mlInvoked ?? this.mlInvoked,
      rawLogits: rawLogits ?? this.rawLogits,
      riskScore: riskScore ?? this.riskScore,
      quarantineThreshold: quarantineThreshold ?? this.quarantineThreshold,
      decision: decision ?? this.decision,
      reason: reason ?? this.reason,
      explanations: explanations ?? this.explanations,
      needsRescan: needsRescan ?? this.needsRescan,
      heuristicScore: heuristicScore ?? this.heuristicScore,
      modelScore: modelScore ?? this.modelScore,
      riskLevel: riskLevel ?? this.riskLevel,
      detectionSource: detectionSource ?? this.detectionSource,
      pipelineStage: pipelineStage ?? this.pipelineStage,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PIPELINE DATA MODELS
//
// Typed output produced at each stage boundary. Makes the top-to-bottom data
// flow explicit and independently testable.
// ─────────────────────────────────────────────────────────────────────────────

/// Stage 1 output — normalized message body forwarded to the Heuristic Layer.
class Stage1Result {
  const Stage1Result({required this.body, required this.source});
  final String body;
  final String source;
}

/// Stage 2 output — result of URL detection and trusted-domain lookup.
///
/// Routing:
///   hasUrl == false              → no URL, route to inbox
///   hasUrl == true, isKnownSafe  → trusted URL, route to inbox
///   hasUrl == true, !isKnownSafe → unknown URL, forward to DistilBERT
class Stage2Result {
  const Stage2Result({
    required this.hasUrl,
    required this.isKnownSafe,
    required this.extractedUrls,
    this.primaryUrl,
    this.primaryDomain,
  });

  final bool hasUrl;
  final bool isKnownSafe;
  final List<String> extractedUrls;
  final String? primaryUrl;
  final String? primaryDomain;
}

/// Stage 3 output — raw logits from the DistilBERT classifier head.
class Stage3Result {
  const Stage3Result({
    required this.logits,
    required this.positiveIndex,
    required this.modelInvoked,
  });

  final List<double> logits;
  final int positiveIndex;
  final bool modelInvoked;
}

/// Stage 4 output — softmax-calibrated smishing probability ∈ [0.0, 1.0].
class Stage4Result {
  const Stage4Result({
    required this.smishingProbability,
    required this.riskLevel,
  });

  final double smishingProbability;
  final String riskLevel;
}

// ─────────────────────────────────────────────────────────────────────────────
// URL EXTRACTOR
//
// Finds, normalises, and defangs URLs in raw message text.
// Handles attacker-obfuscated formats:
//   • hxxps[://]  / hxxp[://]  — threat-intel defang notation
//   • [.]  (dot notation)      — manual dot replacement
//   • Bare domains (no scheme) — e.g. "gcash-secure.ph/login"
// ─────────────────────────────────────────────────────────────────────────────

/// Finds URLs in SMS/chat text and converts attacker-defanged forms into
/// normal URLs the rest of the pipeline can parse.
class UrlExtractor {
  UrlExtractor._internal();

  static final UrlExtractor instance = UrlExtractor._internal();
  factory UrlExtractor() => instance;

  static final RegExp _schemedUrlPattern = RegExp(
    r'(?:(?:https?|hxxps?|hxxp)://|(?:https?|hxxps?|hxxp)\[:\]//|hxxps?\[\://\]|https?\[\://\]|www\.)[^\s<>()]+',
    caseSensitive: false,
  );

  static final RegExp _bareDomainPattern = RegExp(
    r'(?<![@\w])(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,24})(?:/[^\s<>()]*)?',
    caseSensitive: false,
  );

  /// Extracts unique URLs/domains in first-seen order.
  List<String> extractUrls(String text) {
    final matches = <String>[];
    final seen = <String>{};

    void collect(RegExp pattern) {
      for (final Match match in pattern.allMatches(text)) {
        final raw = _sanitizeExtractedUrl(match.group(0) ?? '');
        if (raw.isEmpty) continue;
        if (seen.add(raw.toLowerCase())) matches.add(raw);
      }
    }

    collect(_schemedUrlPattern);
    collect(_bareDomainPattern);
    return matches;
  }

  /// Converts bare or defanged URLs into a parseable http/https URL.
  String normalizeUrl(String rawUrl) {
    var cleaned = _sanitizeExtractedUrl(rawUrl);
    cleaned = cleaned
        .replaceAll(RegExp(r'^hxxps\[:\]//', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^hxxp\[:\]//', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^https\[:\]//', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^http\[:\]//', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^hxxps\[://\]', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^hxxp\[://\]', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^https\[://\]', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^http\[://\]', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^hxxps://', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^hxxp://', caseSensitive: false), 'http://')
        .replaceAll('[.]', '.');
    cleaned = _sanitizeExtractedUrl(cleaned);
    if (cleaned.startsWith('www.')) cleaned = 'https://$cleaned';
    if (!cleaned.contains('://')) cleaned = 'https://$cleaned';
    return cleaned;
  }

  /// Returns the lowercase host without a leading "www." prefix.
  String extractDomain(String rawUrl) {
    try {
      final uri = Uri.parse(normalizeUrl(rawUrl));
      final host = uri.host.toLowerCase();
      return host.startsWith('www.') ? host.substring(4) : host;
    } catch (_) {
      final fallback = rawUrl
          .trim()
          .toLowerCase()
          .replaceAll('[.]', '.')
          .replaceAll(RegExp(r'^https?://'), '');
      return fallback.split('/').first.replaceFirst('www.', '');
    }
  }

  /// Converts a URL into safe display form so it is not clickable.
  String defangUrl(String rawUrl) {
    final normalized = normalizeUrl(rawUrl);
    final defanged = normalized
        .replaceAll('https://', 'hxxps[:]//')
        .replaceAll('http://', 'hxxp[:]//');
    final separator = defanged.indexOf('://');
    if (separator < 0) return defanged.replaceAll('.', '[.]');
    final prefix = defanged.substring(0, separator + 3);
    final suffix = defanged.substring(separator + 3).replaceAll('.', '[.]');
    return '$prefix$suffix';
  }

  /// Removes punctuation that often surrounds URLs in natural language text.
  String _sanitizeExtractedUrl(String input) {
    var value = input.trim();
    while (value.isNotEmpty) {
      final trimmed = value
          .replaceFirst(RegExp("^[<\\(\\[\\{'\"`;,+]+"), '')
          .replaceFirst(RegExp("[>\\)\\]\\}'\"`;,+]+\$"), '')
          .replaceFirst(RegExp(r'[\.,!?;:]+$'), '');
      if (trimmed == value) break;
      value = trimmed.trim();
    }
    return value;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// URL DEFANGER
//
// Rewrites all URLs in a text block into defanged form for safe display in
// the quarantine screen. Uses UrlExtractor for detection.
//   Input : "Visit https://evil.com/login now"
//   Output: "Visit hxxps[:]//evil[.]com/login now"
// ─────────────────────────────────────────────────────────────────────────────

/// Rewrites every URL found in a message into non-clickable display text.
class UrlDefanger {
  UrlDefanger._internal();

  static final UrlDefanger instance = UrlDefanger._internal();
  factory UrlDefanger() => instance;

  final UrlExtractor _urlExtractor = UrlExtractor();

  /// Defangs all detected URLs while preserving the rest of the message.
  String defangText(String rawText) {
    String output = rawText;
    final Set<String> urls = _urlExtractor.extractUrls(rawText).toSet();
    for (final String url in urls) {
      output = output.replaceAll(url, _urlExtractor.defangUrl(url));
    }
    return output;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TRUSTED DOMAIN MODEL
//
// SQLite row model for user-managed trusted domains persisted in the local
// encrypted database. Read and written by DomainAllowlist (Layer 3).
// ─────────────────────────────────────────────────────────────────────────────

/// Local database row for a trusted domain added by seeds or the user.
class TrustedDomainModel {
  const TrustedDomainModel({
    required this.domain,
    required this.source,
    required this.note,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String domain;
  final String source;
  final String? note;
  final int createdAtMs;
  final int updatedAtMs;

  /// Serializes this trusted-domain row for SQLite writes.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'domain': domain,
        'source': source,
        'note': note,
        'createdAtMs': createdAtMs,
        'updatedAtMs': updatedAtMs,
      };

  /// Rebuilds a trusted-domain row from SQLite column values.
  factory TrustedDomainModel.fromMap(Map<String, dynamic> map) =>
      TrustedDomainModel(
        domain: map['domain']?.toString() ?? '',
        source: map['source']?.toString() ?? 'seed',
        note: map['note']?.toString(),
        createdAtMs: (map['createdAtMs'] as num?)?.toInt() ??
            (map['created_at'] as num?)?.toInt() ??
            0,
        updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ??
            (map['updated_at'] as num?)?.toInt() ??
            0,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// STATIC DOMAIN ALLOWLIST
//
// Compile-time hardcoded set of ~370 trusted Philippine and international
// domains. Layer 2 of the three-layer DomainAllowlist lookup:
//   Layer 1 — runtime in-memory cache (O(1) hash, populated from SQLite)
//   Layer 2 — this static set (compile-time, no I/O)
//   Layer 3 — encrypted SQLite (user-managed trusted domains)
// ─────────────────────────────────────────────────────────────────────────────

/// Built-in trusted root-domain list used before consulting local storage.
class StaticDomainAllowlist {
  static const Set<String> _trustedDomains = {
    // ══ PHILIPPINE GOVERNMENT ══════════════════════════════════════════════════
    'gov.ph', 'senate.gov.ph', 'congress.gov.ph', 'judiciary.gov.ph',
    'sc.judiciary.gov.ph',
    'president.gov.ph', 'op.gov.ph', 'ovp.gov.ph', 'pcoo.gov.ph',
    'dof.gov.ph', 'bir.gov.ph', 'boc.gov.ph', 'bsp.gov.ph', 'neda.gov.ph',
    'dti.gov.ph', 'sec.gov.ph', 'ic.gov.ph', 'cda.gov.ph', 'pse.com.ph',
    'dswd.gov.ph', 'sss.gov.ph', 'gsis.gov.ph', 'philhealth.gov.ph',
    'pagibig.gov.ph', 'hdmf.gov.ph', 'dole.gov.ph', 'owwa.gov.ph',
    'poea.gov.ph', 'doh.gov.ph', 'phic.gov.ph',
    'dpwh.gov.ph', 'dot.gov.ph', 'dotc.gov.ph', 'lto.gov.ph', 'ltfrb.gov.ph',
    'marina.gov.ph', 'caap.gov.ph', 'naia.gov.ph', 'miaa.gov.ph',
    'dilg.gov.ph', 'pnp.gov.ph', 'bjmp.gov.ph', 'bucor.gov.ph', 'doj.gov.ph',
    'nbi.gov.ph', 'immigration.gov.ph', 'doi.gov.ph',
    'psa.gov.ph', 'comelec.gov.ph', 'philsys.gov.ph',
    'deped.gov.ph', 'ched.gov.ph', 'tesda.gov.ph', 'up.edu.ph', 'dlsu.edu.ph',
    'ateneo.edu.ph', 'ust.edu.ph', 'admu.edu.ph', 'feu.edu.ph', 'pup.edu.ph',
    'tip.edu.ph',
    'dfa.gov.ph', 'dnd.gov.ph', 'afp.mil.ph', 'passport.gov.ph',
    'denr.gov.ph', 'da.gov.ph', 'bfar.gov.ph', 'pagasa.dost.gov.ph',
    'dost.gov.ph', 'phivolcs.dost.gov.ph', 'ndrrmc.gov.ph',
    'manila.gov.ph', 'quezon-city.gov.ph', 'makati.gov.ph', 'taguig.gov.ph',
    'pasig.gov.ph', 'cebu.gov.ph', 'davao.gov.ph',

    // ══ PHILIPPINE BANKS ═══════════════════════════════════════════════════════
    'bdo.com.ph', 'bpi.com.ph', 'metrobank.com.ph', 'mbtc.com.ph',
    'landbank.com', 'lbp.com.ph', 'dbp.ph', 'unionbankph.com',
    'unionbank.com.ph', 'rcbc.com', 'rcbcsavings.com', 'securitybank.com',
    'chinabank.ph', 'eastwestbanker.com', 'psbank.com.ph', 'maybank.com.ph',
    'pnb.com.ph', 'alliedbank.com.ph', 'aub.com.ph', 'bankofcommerce.com.ph',
    'cimbbank.com.ph', 'gotymeb.com', 'bnkd.ph', 'tonik.com.ph',
    'overseas-filipino-bank.com', 'seabank.com.ph', 'robinsonsbank.com.ph',
    'ibank.com.ph', 'starpay.com.ph', 'ofw-bank.com.ph',

    // ══ E-WALLETS & FINTECH ════════════════════════════════════════════════════
    'gcash.com', 'maya.ph', 'paymaya.com', 'coins.ph', 'grabpay.com',
    'grabpay.com.ph', 'shopeepay.com.ph', 'lazwallet.com', 'paypal.com',
    'wise.com', 'remitly.com', 'westernunion.com', 'moneygram.com',
    'instapay.ph', 'pesonet.ph', 'phzeus.com',

    // ══ PHILIPPINE TELCOS ══════════════════════════════════════════════════════
    'globe.com.ph', 'globeone.com.ph', 'tnt.com.ph', 'smart.com.ph',
    'smartcommunications.com.ph', 'sun.net.ph', 'dito.ph',
    'ditotelecommunity.com', 'pldt.com', 'pldthome.com', 'convergeict.com',
    'skycable.com', 'cignal.tv',

    // ══ E-COMMERCE & DELIVERY ══════════════════════════════════════════════════
    'shopee.ph', 'lazada.com.ph', 'zalora.com.ph', 'carousell.ph',
    'metrodeal.com', 'ensogo.com.ph', 'ebay.ph', 'amazon.com',
    'aliexpress.com', 'temu.com', 'shein.com',
    'jntexpress.com.ph', 'ninjavan.com', 'lbcexpress.com', 'lbc.com.ph',
    'xend.com.ph', 'airspeed.com.ph', '2go.com.ph', 'grab.com',
    'foodpanda.com.ph', 'angkas.com', 'joyride.com.ph', 'mysuki.ph',

    // ══ HEALTHCARE ═════════════════════════════════════════════════════════════
    'healthway.com.ph', 'makatimedcenter.com', 'stlukesmedicalcenter.com',
    'themedicalcity.com', 'asianhospital.com', 'uermmc.edu.ph', 'ncmh.gov.ph',
    'ritm.gov.ph', 'pcso.gov.ph', 'rose-pharmacy.com', 'generika.com.ph',
    'southstardrugph.com', 'mercury-drug.com', 'mercurydrug.com',
    'watsons.com.ph',

    // ══ UTILITIES ══════════════════════════════════════════════════════════════
    'meralco.com.ph', 'maynilad.com.ph', 'mwss.gov.ph', 'mwd.com.ph',
    'petron.com', 'shellph.com', 'caltex.com.ph', 'phoenix-fuels.com',
    'cleanfuel.com.ph', 'pilipinasshell.com',

    // ══ NEWS & MEDIA ═══════════════════════════════════════════════════════════
    'rappler.com', 'inquirer.net', 'philstar.com', 'abs-cbn.com',
    'gmanetwork.com', 'gma.com.ph', 'manilabulletin.com', 'manilatimes.net',
    'sunstar.com.ph', 'pna.gov.ph', 'pia.gov.ph', 'pcij.org',
    'businessworld.com.ph', 'businessmirror.com.ph', 'cnnphilippines.com',
    'interaksyon.com', 'mb.com.ph', 'malaya.com.ph',

    // ══ INTERNATIONAL — SOCIAL MEDIA ══════════════════════════════════════════
    'facebook.com', 'fb.com', 'messenger.com', 'instagram.com', 'twitter.com',
    'x.com', 'linkedin.com', 'tiktok.com', 'youtube.com', 'youtu.be',
    'snapchat.com', 'pinterest.com', 'reddit.com', 'discord.com',
    'telegram.org', 't.me', 'whatsapp.com', 'signal.org', 'viber.com',
    'skype.com', 'zoom.us', 'meet.google.com', 'teams.microsoft.com',

    // ══ INTERNATIONAL — TECH & EMAIL ══════════════════════════════════════════
    'google.com', 'gmail.com', 'accounts.google.com', 'drive.google.com',
    'docs.google.com', 'forms.google.com', 'play.google.com', 'microsoft.com',
    'office.com', 'outlook.com', 'live.com', 'hotmail.com', 'apple.com',
    'icloud.com', 'yahoo.com', 'ymail.com', 'proton.me', 'protonmail.com',
    'dropbox.com', 'onedrive.com', 'box.com', 'github.com', 'gitlab.com',
    'stackoverflow.com', 'medium.com', 'wordpress.com', 'blogspot.com',
    'wikipedia.org',

    // ══ INTERNATIONAL — TRAVEL & TRANSPORT ════════════════════════════════════
    'airasia.com', 'cebuair.com', 'philippineairlines.com', 'pal.com.ph',
    'skyjet.com.ph', 'sunlight-air.com.ph', 'booking.com', 'agoda.com',
    'airbnb.com', 'tripadvisor.com', 'klook.com', 'traveloka.com',

    // ══ INTERNATIONAL — STREAMING & ENTERTAINMENT ═════════════════════════════
    'netflix.com', 'spotify.com', 'disneyplus.com', 'hbomax.com', 'viu.com',
    'wetv.vip', 'vivamax.net',

    // ══ CYBERSECURITY & SAFETY ════════════════════════════════════════════════
    'dict.gov.ph', 'cicc.gov.ph', 'pnp-acg.com', 'cybercrime.gov.ph',
    'dicts.gov.ph', 'virustotal.com', 'haveibeenpwned.com',
  };

  /// Returns true when the URL host matches a trusted root or subdomain.
  static bool isUrlTrusted(String url) => _isTrustedDomain(_extractDomain(url));

  static bool _isTrustedDomain(String domain) {
    if (_trustedDomains.contains(domain)) return true;
    for (final trusted in _trustedDomains) {
      if (domain.endsWith('.$trusted') || domain == trusted) return true;
    }
    return false;
  }

  static String _extractDomain(String url) {
    try {
      String cleaned = url
          .replaceAll('hxxps[://]', 'https://')
          .replaceAll('hxxp[://]', 'http://')
          .replaceAll('[.]', '.');
      if (!cleaned.startsWith('http')) cleaned = 'https://$cleaned';
      final uri = Uri.parse(cleaned);
      final host = uri.host.toLowerCase();
      return host.startsWith('www.') ? host.substring(4) : host;
    } catch (e) {
      return url.toLowerCase();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DOMAIN ALLOWLIST
//
// Three-layer trusted-domain lookup used by Stage 2 to decide whether a URL
// in a message is trusted without running DistilBERT inference:
//
//   Layer 1 — Runtime in-memory cache (Set<String>)          O(1) hash lookup
//   Layer 2 — StaticDomainAllowlist (~370 hardcoded domains)  O(n) scan, no I/O
//   Layer 3 — User-managed encrypted SQLite                  async, result cached
//
// All layers support subdomain-aware matching so subdomains of trusted roots
// automatically pass (e.g. "mail.bpi.com.ph" matches "bpi.com.ph").
// ─────────────────────────────────────────────────────────────────────────────

/// Combines runtime cache, built-in domains, and SQLite trusted domains.
///
/// Stage 2 uses this service to decide whether every URL in a message can skip
/// DistilBERT and go directly to the inbox.
class DomainAllowlist {
  DomainAllowlist._internal();

  static final DomainAllowlist instance = DomainAllowlist._internal();
  factory DomainAllowlist() => instance;

  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final UrlExtractor _urlExtractor = UrlExtractor();

  final Set<String> _cachedTrustedDomains = <String>{};
  bool _primed = false;

  /// Loads user-managed trusted domains into the in-memory cache once.
  Future<void> initialize() async {
    if (_primed) return;
    await _repository.initialize();
    final List<TrustedDomainModel> domains =
        await _repository.listTrustedDomains();
    _cachedTrustedDomains
      ..clear()
      ..addAll(domains.map((TrustedDomainModel d) => d.domain));
    _primed = true;
  }

  /// Synchronous trust check using only cache and static domains.
  bool isUrlTrustedCached(String url) {
    final domain = _normalizeDomain(url);
    return _isInMemoryCache(domain) || StaticDomainAllowlist.isUrlTrusted(url);
  }

  /// Full trust check, including SQLite lookup when cache/static checks miss.
  Future<bool> isUrlTrusted(String url) async {
    await initialize();
    final domain = _normalizeDomain(url);
    if (_isInMemoryCache(domain)) return true;
    if (StaticDomainAllowlist.isUrlTrusted(url)) return true;
    final bool stored = await _repository.isTrustedDomain(domain);
    if (stored) _cachedTrustedDomains.add(domain);
    return stored;
  }

  /// Returns true only when every URL is trusted; null means there were no URLs.
  Future<bool?> areAllUrlsTrusted(List<String> urls) async {
    if (urls.isEmpty) return null;
    for (final String url in urls) {
      if (!await isUrlTrusted(url)) return false;
    }
    return true;
  }

  /// Produces per-URL trust details for UI/debug screens.
  Future<List<Map<String, dynamic>>> analyzeUrls(List<String> urls) async {
    await initialize();
    return <Map<String, dynamic>>[
      for (final String url in urls)
        <String, dynamic>{
          'url': url,
          'domain': _normalizeDomain(url),
          'trusted': _isInMemoryCache(_normalizeDomain(url)) ||
              StaticDomainAllowlist.isUrlTrusted(url),
        },
    ];
  }

  /// Adds or updates a trusted domain, then keeps the cache in sync.
  Future<void> addTrustedDomain({
    required String rawDomainOrUrl,
    required String source,
    String? note,
  }) async {
    await initialize();
    final domain = _normalizeDomain(rawDomainOrUrl);
    if (domain.isEmpty) return;
    _cachedTrustedDomains.add(domain);
    await _repository.upsertTrustedDomain(
      domain: domain,
      source: source,
      note: note,
    );
  }

  String _normalizeDomain(String raw) =>
      _urlExtractor.extractDomain(raw).toLowerCase().trim();

  bool _isInMemoryCache(String domain) {
    if (_cachedTrustedDomains.contains(domain)) return true;
    return _cachedTrustedDomains
        .any((String t) => domain == t || domain.endsWith('.$t'));
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 2 — HEURISTIC LAYER (URL DETECTION + TRUSTED DOMAIN LOOKUP)
//
//  Check 1 — URL Detection (Regex)
//    Detects: http(s), www, IPv4, bare naked domains, defanged URLs, spelled dots
//    URL found → Check 2
//    No URL    → Inbox
//
//  Check 2 — Trusted Domain Lookup (Three-Layer DomainAllowlist)
//    URL trusted  → Inbox
//    URL unknown  → Stage 3 (DistilBERT)
// ─────────────────────────────────────────────────────────────────────────────

/// Stage 2: extracts URLs and checks whether all detected domains are trusted.
class AllowlistFilterStage {
  static const String _tag = '[Stage 2 · Heuristic Layer]';

  final UrlExtractor _urlExtractor = UrlExtractor();
  final DomainAllowlist _trustedDomains = DomainAllowlist();

  /// Routes no-URL and trusted-URL messages away from model inference.
  Future<Stage2Result> check(Stage1Result stage1) async {
    final List<String> urls = _urlExtractor.extractUrls(stage1.body);
    final String? primaryUrl = urls.isEmpty ? null : urls.first;
    final String? primaryDomain =
        primaryUrl == null ? null : _urlExtractor.extractDomain(primaryUrl);

    if (urls.isEmpty) {
      debugPrint('$_tag No URL found → inbox');
      return const Stage2Result(
        hasUrl: false,
        isKnownSafe: false,
        extractedUrls: <String>[],
        primaryUrl: null,
        primaryDomain: null,
      );
    }

    bool allTrusted = true;
    for (final String url in urls) {
      if (!await _trustedDomains.isUrlTrusted(url)) {
        allTrusted = false;
        break;
      }
    }

    debugPrint(
      '$_tag URL found — primaryDomain=$primaryDomain '
      '→ ${allTrusted ? "trusted (inbox)" : "untrusted → DistilBERT"}',
    );

    return Stage2Result(
      hasUrl: true,
      isKnownSafe: allTrusted,
      extractedUrls: urls,
      primaryUrl: primaryUrl,
      primaryDomain: primaryDomain,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DISTILBERT MODEL
//
// Owns the lifecycle of the on-device DistilBERT TFLite interpreter:
// loading, tokenization (WordPiece), inference, and release.
//
// WordPiece tokenization pipeline (mirrors training-time pre-processing):
//   1. Clean & lowercase text  (configurable via tokenizer_config.json)
//   2. Basic tokenization      (split on whitespace and punctuation)
//   3. WordPiece sub-word      (split unknown words into known vocabulary pieces)
//   4. Build tensors           ([CLS] + tokens + [SEP], padded to max_seq_length)
//   5. TFLite inference        → raw logits [safe_score, smishing_score]
//
// Device guard: on Android ≤192 MB memory class or ≤1536 MB total RAM the
// model load is skipped. runInference() returns null and Stage 4 falls back to
// zero-probability (message delivered to inbox, flagged for rescan).
//
// Asset dependencies:
//   assets/distilbert_model.tflite  — 6-layer transformer quantised for mobile
//   assets/tokenizer.json           — WordPiece vocabulary (primary source)
//   assets/vocab.txt                — Fallback vocabulary (plain text)
//   assets/tokenizer_config.json    — do_lower_case, cls/sep/unk tokens
//   assets/config.json              — id2label, max_position_embeddings
// ─────────────────────────────────────────────────────────────────────────────

/// Output produced by a single DistilBERT inference pass.
class ModelOutput {
  const ModelOutput({required this.logits, required this.positiveIndex});
  final List<double> logits;
  final int positiveIndex;
}

/// Manages the DistilBERT TFLite interpreter: loads model assets, tokenizes
/// input text with WordPiece, runs inference, and returns raw logits.
/// Singleton wrapper around the TFLite DistilBERT classifier.
///
/// It owns asset loading, WordPiece tokenization, tensor construction,
/// inference, and memory-based device guards.
class DistilBertModel {
  DistilBertModel._internal();

  static final DistilBertModel instance = DistilBertModel._internal();
  factory DistilBertModel() => instance;

  static const String _configAssetPath = 'assets/config.json';
  static const String _modelAssetPath = 'assets/distilbert_model.tflite';
  static const String _tokenizerAssetPath = 'assets/tokenizer.json';
  static const String _tokenizerConfigAssetPath =
      'assets/tokenizer_config.json';
  static const String _vocabAssetPath = 'assets/vocab.txt';

  static const int _mobileMaxSequenceLength = 256;
  static const int _lowRamMemoryClassMb = 64;
  static const int _lowRamTotalMemoryMb = 512;

  bool _modelLoaded = false;
  bool _loadFailed = false;
  Future<void>? _loadFuture;
  Interpreter? _interpreter;
  Map<String, int> _vocab = <String, int>{};
  int _modelMaxLength = _mobileMaxSequenceLength;
  bool _doLowerCase = false;
  int _padTokenId = 0;
  String _clsToken = '[CLS]';
  String _sepToken = '[SEP]';
  String _unkToken = '[UNK]';
  int _positiveIndex = 1;
  _DevicePerformanceProfile? _deviceProfile;
  Future<_DevicePerformanceProfile>? _deviceProfileFuture;
  String? _skipReason;

  /// Whether the interpreter and tokenizer assets are ready for inference.
  bool get isModelLoaded => _modelLoaded;

  /// Human-readable reason when model loading was intentionally skipped.
  String? get skipReason => _skipReason;

  // ── Model lifecycle ──────────────────────────────────────────────────────────

  /// Loads tokenizer/config/model assets and creates the TFLite interpreter.
  Future<void> loadModel() async {
    if (_modelLoaded || _loadFailed) return;
    final Future<void>? inFlight = _loadFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    _loadFuture = () async {
      if (_modelLoaded || _loadFailed) return;

      final profile = await _getDevicePerformanceProfile();
      if (_shouldSkipForPerformance(profile)) {
        _skipReason = 'DistilBERT disabled on low-memory device '
            '(memoryClass=${profile.memoryClassMb}MB, '
            'totalRam=${profile.totalRamMb}MB).';
        _loadFailed = true;
        debugPrint('[DistilBertModel] $_skipReason');
        return;
      }

      try {
        final Map<String, dynamic> config = jsonDecode(
          await rootBundle.loadString(_configAssetPath),
        ) as Map<String, dynamic>;
        final Map<String, dynamic> tokenizerConfig = jsonDecode(
          await rootBundle.loadString(_tokenizerConfigAssetPath),
        ) as Map<String, dynamic>;

        _vocab = await _loadVocabulary();

        final configuredMaxLength =
            (tokenizerConfig['model_max_length'] as num?)?.toInt() ??
                (config['max_position_embeddings'] as num?)?.toInt() ??
                _mobileMaxSequenceLength;
        _modelMaxLength =
            math.min(configuredMaxLength, _mobileMaxSequenceLength);

        _doLowerCase = tokenizerConfig['do_lower_case'] == true;
        _padTokenId = (config['pad_token_id'] as num?)?.toInt() ?? 0;
        _clsToken = tokenizerConfig['cls_token']?.toString() ?? '[CLS]';
        _sepToken = tokenizerConfig['sep_token']?.toString() ?? '[SEP]';
        _unkToken = tokenizerConfig['unk_token']?.toString() ?? '[UNK]';

        final Map<String, dynamic>? id2Label =
            config['id2label'] as Map<String, dynamic>?;
        if (id2Label != null) {
          for (final entry in id2Label.entries) {
            if (entry.value.toString().toLowerCase() == 'spam') {
              _positiveIndex = int.tryParse(entry.key) ?? 1;
              break;
            }
          }
        }

        final options = InterpreterOptions()..threads = 1;
        _interpreter =
            await Interpreter.fromAsset(_modelAssetPath, options: options);
        _modelLoaded = true;
        _loadFailed = false;
        _skipReason = null;
        debugPrint(
            '[DistilBertModel] Loaded (vocab=${_vocab.length}, maxLen=$_modelMaxLength).');
      } catch (error) {
        _modelLoaded = false;
        _loadFailed = true;
        _interpreter = null;
        _vocab = <String, int>{};
        debugPrint('[DistilBertModel] Load failed: $error');
      }
    }();

    try {
      await _loadFuture;
    } finally {
      _loadFuture = null;
    }
  }

  /// Runs a single normalized message through DistilBERT.
  ///
  /// Returns null when the model cannot be loaded or inference fails.
  Future<ModelOutput?> runInference(String normalizedMessage) async {
    await loadModel();
    if (!_modelLoaded || _interpreter == null) return null;

    try {
      final _EncodedModelInput encoded = _encodeForModel(normalizedMessage);
      final List<Tensor> inputTensors = _interpreter!.getInputTensors();
      final List<Object?> inputs =
          List<Object?>.filled(inputTensors.length, null);

      for (int i = 0; i < inputTensors.length; i++) {
        final String name = inputTensors[i].name.toLowerCase();
        if (name.contains('input_ids')) {
          inputs[i] = encoded.inputIds;
        } else if (name.contains('attention_mask')) {
          inputs[i] = encoded.attentionMask;
        } else if (name.contains('token_type_ids')) {
          inputs[i] = encoded.tokenTypeIds;
        }
      }

      if (inputs.any((v) => v == null)) {
        final List<Object> fallback = <Object>[
          encoded.inputIds,
          encoded.attentionMask,
          if (inputTensors.length > 2) encoded.tokenTypeIds,
        ];
        for (int i = 0; i < inputTensors.length; i++) {
          inputs[i] = fallback[i];
        }
      }

      final List<Tensor> outputTensors = _interpreter!.getOutputTensors();
      if (outputTensors.isEmpty) return null;
      final Tensor outputTensor = outputTensors.first;
      final int cols =
          outputTensor.shape.isNotEmpty ? outputTensor.shape.last : 2;
      if (cols == 0) return null;
      final List<List<double>> output =
          List.generate(1, (_) => List<double>.filled(cols, 0.0));

      _interpreter!.runForMultipleInputs(
          inputs.cast<Object>(), <int, Object>{0: output});
      return ModelOutput(logits: output.first, positiveIndex: _positiveIndex);
    } catch (error) {
      debugPrint('[DistilBertModel] Inference failed: $error');
      return null;
    }
  }

  /// Performs a tiny inference to pay one-time interpreter setup cost early.
  Future<void> _warmUp() async {
    if (!_modelLoaded || _interpreter == null) return;
    final Stopwatch stopwatch = Stopwatch()..start();
    final ModelOutput? output = await runInference('model warmup');
    stopwatch.stop();
    debugPrint(
      '[DistilBertModel] Warm-up '
      '${output == null ? "failed" : "complete"} '
      '(${stopwatch.elapsedMilliseconds}ms).',
    );
  }

  /// Closes the interpreter and marks the model as unloaded.
  Future<void> releaseModel() async {
    try {
      _interpreter?.close();
    } catch (_) {}
    _interpreter = null;
    _modelLoaded = false;
    if (!_loadFailed) _skipReason = null;
  }

  /// Loads the model inside a background isolate using text assets that were
  /// pre-loaded by the main isolate (avoids rootBundle.loadString which requires
  /// ServicesBinding.instance — unavailable in background isolates).
  /// Interpreter.fromAsset uses a platform channel and works fine here.
  /// Loads the model inside the worker isolate from main-isolate assets.
  Future<void> _loadWithTextAssets(_IsolateBootstrap bootstrap) async {
    if (_modelLoaded || _loadFailed) return;
    try {
      final Map<String, dynamic> config =
          jsonDecode(bootstrap.config) as Map<String, dynamic>;
      final Map<String, dynamic> tokenizerConfig =
          jsonDecode(bootstrap.tokenizerConfig) as Map<String, dynamic>;

      // Parse vocab from tokenizer.json; fall back to vocab.txt.
      _vocab = _parseVocabFromJsonString(bootstrap.tokenizerJson);
      if (_vocab.isEmpty) {
        _vocab = _parseVocabFromTxtString(bootstrap.vocab);
      }

      final int configuredMaxLength =
          (tokenizerConfig['model_max_length'] as num?)?.toInt() ??
              (config['max_position_embeddings'] as num?)?.toInt() ??
              _mobileMaxSequenceLength;
      _modelMaxLength = math.min(configuredMaxLength, _mobileMaxSequenceLength);

      _doLowerCase = tokenizerConfig['do_lower_case'] == true;
      _padTokenId = (config['pad_token_id'] as num?)?.toInt() ?? 0;
      _clsToken = tokenizerConfig['cls_token']?.toString() ?? '[CLS]';
      _sepToken = tokenizerConfig['sep_token']?.toString() ?? '[SEP]';
      _unkToken = tokenizerConfig['unk_token']?.toString() ?? '[UNK]';

      final Map<String, dynamic>? id2Label =
          config['id2label'] as Map<String, dynamic>?;
      if (id2Label != null) {
        for (final entry in id2Label.entries) {
          if (entry.value.toString().toLowerCase() == 'spam') {
            _positiveIndex = int.tryParse(entry.key) ?? 1;
            break;
          }
        }
      }

      // Use the model bytes pre-loaded by the main isolate. We can't use
      // Interpreter.fromAsset here because it internally calls rootBundle.load,
      // which accesses ServicesBinding.instance (unavailable in background isolates).
      final InterpreterOptions options = InterpreterOptions()..threads = 1;
      _interpreter =
          Interpreter.fromBuffer(bootstrap.modelBytes, options: options);
      _modelLoaded = true;
      _loadFailed = false;
      _skipReason = null;
      debugPrint('[DistilBertModel] Loaded via isolate bootstrap '
          '(vocab=${_vocab.length}, maxLen=$_modelMaxLength).');
    } catch (error) {
      _modelLoaded = false;
      _loadFailed = true;
      _interpreter = null;
      _vocab = <String, int>{};
      debugPrint('[DistilBertModel] loadWithTextAssets failed: $error');
    }
  }

  /// Extracts the WordPiece vocabulary from Hugging Face tokenizer JSON.
  Map<String, int> _parseVocabFromJsonString(String json) {
    try {
      final Map<String, dynamic> parsed =
          jsonDecode(json) as Map<String, dynamic>;
      final Map<String, dynamic>? vocab = (parsed['model']
          as Map<String, dynamic>?)?['vocab'] as Map<String, dynamic>?;
      if (vocab == null || vocab.isEmpty) return <String, int>{};
      return <String, int>{
        for (final e in vocab.entries) e.key: (e.value as num).toInt(),
      };
    } catch (_) {
      return <String, int>{};
    }
  }

  /// Builds a vocabulary map from one-token-per-line vocab.txt content.
  Map<String, int> _parseVocabFromTxtString(String txt) {
    final List<String> lines = const LineSplitter()
        .convert(txt)
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList(growable: false);
    return <String, int>{
      for (int i = 0; i < lines.length; i++) lines[i]: i,
    };
  }

  // ── WordPiece Tokenization ────────────────────────────────────────────────────

  /// Builds [CLS] + WordPiece sub-tokens + [SEP], padded to max_seq_length.
  /// Converts text into padded input tensors expected by the TFLite model.
  _EncodedModelInput _encodeForModel(String message) {
    final int maxContent = _modelMaxLength > 2 ? _modelMaxLength - 2 : 510;
    final List<String> tokens = _tokenize(message);
    final List<String> truncated =
        tokens.length > maxContent ? tokens.sublist(0, maxContent) : tokens;

    final List<int> inputIds = <int>[
      _tokenIdFor(_clsToken),
      ...truncated.map(_tokenIdFor),
      _tokenIdFor(_sepToken),
    ];
    final List<int> attentionMask =
        List<int>.filled(inputIds.length, 1, growable: true);

    while (inputIds.length < _modelMaxLength) {
      inputIds.add(_padTokenId);
      attentionMask.add(0);
    }

    return _EncodedModelInput(
      inputIds: <List<int>>[inputIds],
      attentionMask: <List<int>>[attentionMask],
      tokenTypeIds: <List<int>>[List<int>.filled(_modelMaxLength, 0)],
    );
  }

  /// Full tokenization: text cleaning → basic tokenization → WordPiece.
  /// Produces WordPiece tokens from cleaned message text.
  List<String> _tokenize(String text) {
    final String cleaned = _cleanTextForTokenizer(text);
    if (cleaned.isEmpty) return const <String>[];
    final List<String> basic = _basicTokenize(cleaned);
    final List<String> pieces = <String>[];
    for (final token in basic) {
      pieces.addAll(_wordPieceTokenize(token));
    }
    return pieces;
  }

  /// Strips control characters, normalises whitespace, optionally lowercases.
  String _cleanTextForTokenizer(String text) {
    final StringBuffer buffer = StringBuffer();
    for (final int rune in text.runes) {
      if (_isControl(rune)) continue;
      buffer.writeCharCode(_isWhitespace(rune) ? 0x0020 : rune);
    }
    final String cleaned = buffer.toString().trim();
    return _doLowerCase ? cleaned.toLowerCase() : cleaned;
  }

  /// Splits on whitespace and isolates punctuation / CJK characters as tokens.
  List<String> _basicTokenize(String text) {
    final List<String> tokens = <String>[];
    final StringBuffer buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) return;
      tokens.add(buffer.toString());
      buffer.clear();
    }

    for (final int rune in text.runes) {
      if (_isWhitespace(rune)) {
        flush();
      } else if (_isChineseChar(rune) || _isPunctuation(rune)) {
        flush();
        tokens.add(String.fromCharCode(rune));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    flush();
    return tokens;
  }

  /// Splits an unknown word into the longest known sub-word pieces.
  /// Returns [[UNK]] if no valid decomposition is found.
  List<String> _wordPieceTokenize(String token) {
    if (token.isEmpty) return const <String>[];
    if (_vocab.containsKey(token)) return <String>[token];

    final List<String> chars =
        token.runes.map((int r) => String.fromCharCode(r)).toList();
    final List<String> subTokens = <String>[];
    int start = 0;

    while (start < chars.length) {
      int end = chars.length;
      String? current;

      while (start < end) {
        final String piece = chars.sublist(start, end).join();
        final String candidate = start == 0 ? piece : '##$piece';
        if (_vocab.containsKey(candidate)) {
          current = candidate;
          break;
        }
        end--;
      }

      if (current == null) return <String>[_unkToken];
      subTokens.add(current);
      start = end;
    }

    return subTokens;
  }

  int _tokenIdFor(String token) => _vocab[token] ?? _vocab[_unkToken] ?? 100;

  bool _isWhitespace(int rune) =>
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0x20 ||
      rune == 0x00A0;

  bool _isControl(int rune) {
    if (rune == 0x09 || rune == 0x0A || rune == 0x0D) return false;
    return rune < 0x20 || rune == 0x7F;
  }

  bool _isPunctuation(int rune) =>
      (rune >= 33 && rune <= 47) ||
      (rune >= 58 && rune <= 64) ||
      (rune >= 91 && rune <= 96) ||
      (rune >= 123 && rune <= 126);

  bool _isChineseChar(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0x20000 && rune <= 0x2A6DF) ||
      (rune >= 0x2A700 && rune <= 0x2B73F) ||
      (rune >= 0x2B740 && rune <= 0x2B81F) ||
      (rune >= 0x2B820 && rune <= 0x2CEAF) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0x2F800 && rune <= 0x2FA1F);

  // ── Vocabulary loading ────────────────────────────────────────────────────────

  /// Loads tokenizer.json vocabulary, falling back to vocab.txt.
  Future<Map<String, int>> _loadVocabulary() async {
    final Map<String, int> fromJson = await _loadVocabFromTokenizerJson();
    if (fromJson.isNotEmpty) return fromJson;

    final String text = await rootBundle.loadString(_vocabAssetPath);
    final List<String> lines = const LineSplitter()
        .convert(text)
        .map((String l) => l.trim())
        .where((String l) => l.isNotEmpty)
        .toList(growable: false);
    return <String, int>{for (int i = 0; i < lines.length; i++) lines[i]: i};
  }

  /// Attempts vocabulary loading from tokenizer.json only.
  Future<Map<String, int>> _loadVocabFromTokenizerJson() async {
    try {
      final Map<String, dynamic> json = jsonDecode(
        await rootBundle.loadString(_tokenizerAssetPath),
      ) as Map<String, dynamic>;
      final Map<String, dynamic>? vocab = (json['model']
          as Map<String, dynamic>?)?['vocab'] as Map<String, dynamic>?;
      if (vocab == null || vocab.isEmpty) return <String, int>{};
      return <String, int>{
        for (final e in vocab.entries) e.key: (e.value as num).toInt(),
      };
    } catch (_) {
      return <String, int>{};
    }
  }

  // ── Device performance guard ─────────────────────────────────────────────────

  /// Reads Android memory information used by the model loading guard.
  Future<_DevicePerformanceProfile> _getDevicePerformanceProfile() async {
    if (_deviceProfile != null) return _deviceProfile!;
    if (_deviceProfileFuture != null) return _deviceProfileFuture!;

    _deviceProfileFuture = () async {
      if (defaultTargetPlatform != TargetPlatform.android) {
        return const _DevicePerformanceProfile();
      }
      try {
        final raw = await NativeChannelRouter.channel
            .invokeMethod<dynamic>('getDevicePerformanceProfile');
        return _DevicePerformanceProfile.fromMap(
          Map<String, dynamic>.from(raw as Map<dynamic, dynamic>? ?? const {}),
        );
      } catch (error) {
        debugPrint('[DistilBertModel] Device profile unavailable: $error');
        return const _DevicePerformanceProfile();
      }
    }();

    try {
      final resolved = await _deviceProfileFuture!;
      _deviceProfile = resolved;
      return resolved;
    } finally {
      _deviceProfileFuture = null;
    }
  }

  bool _shouldSkipForPerformance(_DevicePerformanceProfile p) {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    if (p.isLowRamDevice) return true;
    if (p.memoryClassMb > 0 && p.memoryClassMb <= _lowRamMemoryClassMb) {
      return true;
    }
    if (p.totalRamMb > 0 && p.totalRamMb <= _lowRamTotalMemoryMb) return true;
    return false;
  }
}

/// Batched input tensors sent to the DistilBERT interpreter.
class _EncodedModelInput {
  const _EncodedModelInput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
  });
  final List<List<int>> inputIds;
  final List<List<int>> attentionMask;
  final List<List<int>> tokenTypeIds;
}

/// Android memory profile used to avoid loading DistilBERT on weak devices.
class _DevicePerformanceProfile {
  const _DevicePerformanceProfile({
    this.isLowRamDevice = false,
    this.memoryClassMb = 0,
    this.largeMemoryClassMb = 0,
    this.totalRamMb = 0,
  });

  factory _DevicePerformanceProfile.fromMap(Map<String, dynamic> map) =>
      _DevicePerformanceProfile(
        isLowRamDevice: map['isLowRamDevice'] == true,
        memoryClassMb: (map['memoryClassMb'] as num?)?.toInt() ?? 0,
        largeMemoryClassMb: (map['largeMemoryClassMb'] as num?)?.toInt() ?? 0,
        totalRamMb: (map['totalRamMb'] as num?)?.toInt() ?? 0,
      );

  final bool isLowRamDevice;
  final int memoryClassMb;
  final int largeMemoryClassMb;
  final int totalRamMb;
}

// ─────────────────────────────────────────────────────────────────────────────
// DISTILBERT ISOLATE RUNNER
//
// Executes DistilBERT inference inside a persistent background Dart isolate so
// the UI thread is never blocked by heavy tensor math.
//
//   Main isolate                   Worker isolate
//   ───────────────                ────────────────────────────────
//   DistilBertIsolateRunner  ──►  _workerMain()
//     ensureStarted()               BackgroundIsolateBinaryMessenger.init
//     runInference(text)   ──►      DistilBertModel.runInference(text)
//                          ◄──      ModelOutput (logits, positiveIndex)
//
// Each request is tagged with an integer id so concurrent requests from the
// scan queue never mix up results.
// ─────────────────────────────────────────────────────────────────────────────

/// Persistent background worker that serializes DistilBERT inference requests.
///
/// The UI isolate sends text and receives logits through SendPort messages.
class DistilBertIsolateRunner {
  DistilBertIsolateRunner._internal();

  static final DistilBertIsolateRunner _instance =
      DistilBertIsolateRunner._internal();
  factory DistilBertIsolateRunner() => _instance;

  Isolate? _isolate;
  SendPort? _sendPort;
  Future<void>? _spawnFuture;
  Future<void> _inferenceChain = Future<void>.value();

  int _requestId = 0;
  final Map<int, Completer<ModelOutput?>> _pending =
      <int, Completer<ModelOutput?>>{};
  static const Duration _inferenceTimeout = Duration(seconds: 30);

  /// Starts the worker isolate and preloads model assets from the main isolate.
  Future<void> ensureStarted() async {
    if (_sendPort != null) return;
    final inFlight = _spawnFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    _spawnFuture = () async {
      final RootIsolateToken? rootToken = RootIsolateToken.instance;
      if (rootToken == null) {
        throw StateError('Root isolate token unavailable — '
            'ensure WidgetsFlutterBinding.ensureInitialized() has been called.');
      }

      // Pre-load all assets (text + model bytes) in the main isolate. rootBundle
      // — used internally by both loadString and Interpreter.fromAsset — accesses
      // ServicesBinding.instance which is unavailable in background isolates.
      final String tokenizerJson =
          await rootBundle.loadString(DistilBertModel._tokenizerAssetPath);
      final String tokenizerConfig = await rootBundle
          .loadString(DistilBertModel._tokenizerConfigAssetPath);
      final String config =
          await rootBundle.loadString(DistilBertModel._configAssetPath);
      final String vocab =
          await rootBundle.loadString(DistilBertModel._vocabAssetPath);
      final ByteData modelByteData =
          await rootBundle.load(DistilBertModel._modelAssetPath);
      final Uint8List modelBytes = modelByteData.buffer.asUint8List(
        modelByteData.offsetInBytes,
        modelByteData.lengthInBytes,
      );

      final ReceivePort receivePort = ReceivePort();
      final Completer<void> readyCompleter = Completer<void>();

      receivePort.listen((dynamic message) {
        if (message is SendPort) {
          _sendPort = message;
          if (!readyCompleter.isCompleted) readyCompleter.complete();
          return;
        }
        if (message is! Map) return;

        final int id = (message['id'] as num?)?.toInt() ?? -1;
        final Completer<ModelOutput?>? completer = _pending.remove(id);
        if (completer == null || completer.isCompleted) return;

        final Object? error = message['error'];
        if (error != null) {
          debugPrint('[DistilBertIsolateRunner] Worker error: $error');
          completer.complete(null);
          return;
        }

        final List<double> logits =
            (message['logits'] as List<dynamic>? ?? const <dynamic>[])
                .map((dynamic item) => (item as num).toDouble())
                .toList(growable: false);

        if (logits.isEmpty) {
          debugPrint(
              '[DistilBertIsolateRunner] Worker returned empty logits — treating as inference failure.');
          completer.complete(null);
          return;
        }

        completer.complete(ModelOutput(
          logits: logits,
          positiveIndex: (message['positiveIndex'] as num?)?.toInt() ?? 1,
        ));
      });

      _isolate = await Isolate.spawn<_IsolateBootstrap>(
        _workerMain,
        _IsolateBootstrap(
          sendPort: receivePort.sendPort,
          rootToken: rootToken,
          tokenizerJson: tokenizerJson,
          tokenizerConfig: tokenizerConfig,
          config: config,
          vocab: vocab,
          modelBytes: modelBytes,
        ),
        debugName: 'distilbert_inference_worker',
      );

      await readyCompleter.future;
    }();

    try {
      await _spawnFuture;
    } finally {
      _spawnFuture = null;
    }
  }

  /// Queues one inference request after any currently running request.
  Future<ModelOutput?> runInference(String normalizedMessage) {
    final Future<ModelOutput?> inference = _inferenceChain.then(
      (_) => _sendInferenceRequest(normalizedMessage),
    );
    _inferenceChain = inference.then<void>(
      (_) {},
      onError: (_) {},
    );
    return inference;
  }

  /// Sends one tagged request to the worker and waits for its matching reply.
  Future<ModelOutput?> _sendInferenceRequest(String normalizedMessage) async {
    await ensureStarted();
    final SendPort? port = _sendPort;
    if (port == null) return null;

    final int id = ++_requestId;
    final Completer<ModelOutput?> completer = Completer<ModelOutput?>();
    _pending[id] = completer;

    port.send(<String, dynamic>{'id': id, 'text': normalizedMessage});
    return completer.future.timeout(_inferenceTimeout, onTimeout: () {
      _pending.remove(id);
      debugPrint(
        '[DistilBertIsolateRunner] Inference timed out; '
        'falling back to local risk signals for this request.',
      );
      return null;
    });
  }

  /// Stops the worker and resolves pending requests as failed.
  Future<void> dispose() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    _inferenceChain = Future<void>.value();
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pending.clear();
  }

  /// Worker-isolate entry point: load model, receive requests, return logits.
  static Future<void> _workerMain(_IsolateBootstrap bootstrap) async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(bootstrap.rootToken);
    final DistilBertModel model = DistilBertModel();
    // Load model before accepting requests. Uses pre-loaded text assets from the
    // main isolate (avoids rootBundle.loadString which fails here) and
    // Interpreter.fromAsset which works via platform channel.
    await model._loadWithTextAssets(bootstrap);
    await model._warmUp();
    final ReceivePort requestPort = ReceivePort();
    bootstrap.sendPort.send(requestPort.sendPort);

    await for (final dynamic raw in requestPort) {
      if (raw is! Map) continue;
      final int id = (raw['id'] as num?)?.toInt() ?? -1;
      try {
        final String text = raw['text']?.toString().trim() ?? '';
        final ModelOutput? output = await model.runInference(text);
        if (output == null) {
          bootstrap.sendPort.send(<String, dynamic>{
            'id': id,
            'error':
                'model_returned_null — model may not have loaded in isolate.',
          });
        } else {
          bootstrap.sendPort.send(<String, dynamic>{
            'id': id,
            'logits': output.logits,
            'positiveIndex': output.positiveIndex,
          });
        }
      } catch (error) {
        bootstrap.sendPort
            .send(<String, dynamic>{'id': id, 'error': error.toString()});
      }
    }
  }
}

/// Asset payload needed to initialize the model inside the worker isolate.
class _IsolateBootstrap {
  const _IsolateBootstrap({
    required this.sendPort,
    required this.rootToken,
    required this.tokenizerJson,
    required this.tokenizerConfig,
    required this.config,
    required this.vocab,
    required this.modelBytes,
  });
  final SendPort sendPort;
  final RootIsolateToken rootToken;
  // All assets pre-loaded in the main isolate. rootBundle (used by both
  // loadString and Interpreter.fromAsset internally) requires
  // ServicesBinding.instance, which is unavailable in background isolates.
  final String tokenizerJson;
  final String tokenizerConfig;
  final String config;
  final String vocab;
  final Uint8List modelBytes;
}

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 3 — DEEP LEARNING PIPELINE (DISTILBERT ON-DEVICE)
//
// Runs DistilBERT inside a background isolate so the UI stays responsive.
// Applies the same lightweight text cleanup used by the training script, then
// sends the raw message text to DistilBertIsolateRunner. Returns raw logits for
// Stage 4.
// ─────────────────────────────────────────────────────────────────────────────

/// Stage 3: preprocesses message text and requests DistilBERT inference.
class DeepLearningPipelineStage {
  static const String _tag = '[Stage 3 · Deep Learning Pipeline]';

  final DistilBertIsolateRunner _inferenceWorker = DistilBertIsolateRunner();

  /// Returns model logits when inference succeeds, otherwise an empty result.
  Future<Stage3Result> runInference(String messageBody) async {
    final String normalized = _preprocess(messageBody);
    final Stopwatch stopwatch = Stopwatch()..start();
    final ModelOutput? output = await _inferenceWorker.runInference(normalized);
    stopwatch.stop();

    if (output == null) {
      debugPrint(
          '$_tag Model unavailable — heuristic fallback applied (${stopwatch.elapsedMilliseconds}ms).');
    } else {
      debugPrint(
          '$_tag Inference complete (${stopwatch.elapsedMilliseconds}ms).');
    }

    return Stage3Result(
      logits: output?.logits ?? const <double>[],
      positiveIndex: output?.positiveIndex ?? 1,
      modelInvoked: output != null && (output.logits.isNotEmpty),
    );
  }

  /// Applies the lightweight text cleanup used before tokenizer encoding.
  String _preprocess(String body) {
    var text = body.trim();
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return text;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 4 — PROBABILITY CALCULATION
//
// Applies Softmax to the raw DistilBERT logits and returns the smishing
// probability ∈ [0.0, 1.0]. Pure mathematical transformation — no heuristics.
//
//   Softmax(logits) = exp(l_i - max) / Σ exp(l_j - max)
//   smishingProbability = Softmax[positiveIndex]
// ─────────────────────────────────────────────────────────────────────────────

/// Stage 4: converts raw model logits into a smishing probability.
class ProbabilityCalculationStage {
  static const String _tag = '[Stage 4 · Probability Calculation]';

  final SoftmaxScorer _riskScoring = SoftmaxScorer();

  /// Applies softmax and labels the score as safe/high for routing.
  Future<Stage4Result> calculate(Stage3Result stage3) async {
    double smishingProbability = 0.0;

    if (stage3.modelInvoked && stage3.logits.isNotEmpty) {
      smishingProbability = await _riskScoring.scoreFromLogits(
        stage3.logits,
        positiveIndex: stage3.positiveIndex,
      );
    }

    final String riskLevel = _categorize(smishingProbability);

    debugPrint(
      '$_tag Softmax probability=${smishingProbability.toStringAsFixed(4)} '
      'riskLevel=$riskLevel modelInvoked=${stage3.modelInvoked}',
    );

    return Stage4Result(
        smishingProbability: smishingProbability, riskLevel: riskLevel);
  }

  /// Maps probability to the coarse risk label used by Stage 4 output.
  String _categorize(double probability) {
    return probability >= OutputRouterStage.quarantineThreshold
        ? 'high'
        : 'safe';
  }
}

/// Converts DistilBERT logits to smishing probability via Softmax and provides
/// configurable threshold values stored in local SQLite.
/// Math helper for converting classifier logits into probabilities.
class SoftmaxScorer {
  SoftmaxScorer._internal();

  static final SoftmaxScorer instance = SoftmaxScorer._internal();
  factory SoftmaxScorer() => instance;

  final LocalDetectionRepository _repository = LocalDetectionRepository();

  /// User-configurable threshold stored by the local detection repository.
  Future<double> get quarantineThreshold async =>
      _repository.getQuarantineThreshold();

  /// Numerically stable softmax implementation.
  Future<List<double>> softmax(List<double> logits) async {
    if (logits.isEmpty) return const <double>[];
    final double maxLogit =
        logits.reduce((double a, double b) => a > b ? a : b);
    final List<double> exps = logits
        .map((double v) => math.exp(v - maxLogit))
        .toList(growable: false);
    final double sum =
        exps.fold<double>(0.0, (double acc, double item) => acc + item);
    if (sum == 0) return List<double>.filled(logits.length, 0.0);
    return exps.map((double v) => v / sum).toList(growable: false);
  }

  /// Returns the probability at the configured positive/smishing class index.
  Future<double> scoreFromLogits(List<double> logits,
      {int positiveIndex = 1}) async {
    final List<double> probabilities = await softmax(logits);
    if (probabilities.isEmpty) return 0.0;
    final int smishingIdx =
        positiveIndex >= 0 && positiveIndex < probabilities.length
            ? positiveIndex
            : probabilities.length - 1;
    return probabilities[smishingIdx].clamp(0.0, 1.0);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 5 — OUTPUT ROUTER
//
// Applies a fixed decision threshold of 0.5 to the Stage 4 smishing probability:
//   probability < 0.5  → Inbox      (user can flag as false negative)
//   probability ≥ 0.5  → Quarantine Vault (URL defanged, user notified)
//
// All routing decisions are persisted to the local encrypted SQLite database
// as audit logs and future training signal.
// ─────────────────────────────────────────────────────────────────────────────

/// Stage 5: turns probability and stage metadata into the final app decision.
class OutputRouterStage {
  static const String _tag = '[Stage 5 · Output Router]';

  /// Fixed decision threshold. Messages at or above this value are quarantined.
  /// Lowered from 0.5 to 0.45 — for a security-critical app, 0.5 (the bare
  /// midpoint) lets too many borderline smishing messages through.
  static const double quarantineThreshold = 0.5;

  final LocalDetectionRepository _repository = LocalDetectionRepository();

  /// Builds, saves, and returns the final scan result for a message.
  Future<DetectionResultModel> route({
    required ScreenedMessageModel message,
    required Stage2Result stage2,
    required Stage3Result stage3,
    required Stage4Result stage4,
  }) async {
    final bool modelError = !stage3.modelInvoked;
    final double riskScore = stage4.smishingProbability;
    final bool quarantine = riskScore >= quarantineThreshold;
    final String decision = quarantine
        ? DetectionDecision.quarantineHighRisk
        : modelError
            ? DetectionDecision.modelErrorFallback
            : DetectionDecision.allowLowRisk;

    debugPrint(
      '$_tag decision=$decision '
      'modelScore=${riskScore.toStringAsFixed(3)} '
      'threshold=$quarantineThreshold '
      '→ ${quarantine ? "Quarantine Vault" : "Inbox"}',
    );

    final DetectionResultModel result = DetectionResultModel(
      messageKey: message.messageKey,
      hasUrl: stage2.hasUrl,
      extractedUrls: stage2.extractedUrls,
      primaryUrl: stage2.primaryUrl,
      primaryDomain: stage2.primaryDomain,
      trustedMatch: stage2.isKnownSafe,
      mlInvoked: stage3.modelInvoked,
      rawLogits: stage3.logits,
      riskScore: riskScore,
      quarantineThreshold: quarantineThreshold,
      decision: decision,
      reason: quarantine
          ? 'DistilBERT smishing probability (${riskScore.toStringAsFixed(3)}) '
              'is at or above the $quarantineThreshold threshold — message quarantined.'
          : modelError
              ? 'Model unavailable — message delivered temporarily and queued for rescan.'
              : 'DistilBERT smishing probability (${riskScore.toStringAsFixed(3)}) '
                  'is below the $quarantineThreshold threshold — message delivered to inbox.',
      explanations: _buildExplanations(stage2, stage3, stage4, riskScore),
      needsRescan: modelError && !quarantine,
      heuristicScore: 0.0,
      modelScore: stage3.modelInvoked ? stage4.smishingProbability : null,
      riskLevel: _riskLevel(riskScore),
      detectionSource: stage3.modelInvoked
          ? 'distilbert_pipeline'
          : 'model_unavailable_fallback',
      pipelineStage:
          stage3.modelInvoked ? 'stage_5_output' : 'stage_5_model_unavailable',
    );

    await _repository.saveScreeningResult(result: result, message: message);
    return result;
  }

  /// Creates short UI-facing reasons explaining why the route was chosen.
  List<String> _buildExplanations(
    Stage2Result s2,
    Stage3Result s3,
    Stage4Result s4,
    double riskScore,
  ) {
    final seen = <String>{};
    final reasons = <String>[
      if (s2.primaryDomain != null && !s2.isKnownSafe)
        'Untrusted domain detected: ${s2.primaryDomain}.',
      if (s3.modelInvoked)
        'On-device DistilBERT inference completed — '
            'smishing probability: ${s4.smishingProbability.toStringAsFixed(3)}.',
      if (!s3.modelInvoked)
        'Model unavailable — message delivered temporarily and queued for rescan.',
      if (riskScore >= quarantineThreshold)
        'Smishing probability (${riskScore.toStringAsFixed(3)}) '
            'exceeded quarantine threshold ($quarantineThreshold) → Quarantine Vault.',
    ];

    return reasons.where((reason) => seen.add(reason)).take(5).toList();
  }

  /// Maps numeric risk score into the UI risk-level label.
  String _riskLevel(double score) {
    if (score >= quarantineThreshold) return 'high';
    if (score >= 0.25) return 'medium';
    return 'safe';
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SMISHING PIPELINE — 5-STAGE ORCHESTRATOR
//
//  Stage 1 → Stage 2 → (trusted exit OR) → Stage 3 → Stage 4 → Stage 5
// ═══════════════════════════════════════════════════════════════════════════════

/// Orchestrates the five stages from raw message to final detection result.
class SmishingPipeline {
  SmishingPipeline._();

  static final SmishingPipeline instance = SmishingPipeline._();
  factory SmishingPipeline() => instance;

  static const String _tag = '[SmishingPipeline]';

  final MessageBufferStage _stage1 = MessageBufferStage();
  final AllowlistFilterStage _stage2 = AllowlistFilterStage();
  final DeepLearningPipelineStage _stage3 = DeepLearningPipelineStage();
  final ProbabilityCalculationStage _stage4 = ProbabilityCalculationStage();
  final OutputRouterStage _stage5 = OutputRouterStage();

  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final DomainAllowlist _trustedDomains = DomainAllowlist();

  /// Initializes shared dependencies needed before a deep scan can run.
  Future<void> initialize() async {
    await _repository.initialize();
    await _trustedDomains.initialize();
  }

  /// Runs one message through Stage 1 through Stage 5.
  Future<DetectionResultModel> run(ScreenedMessageModel message) async {
    debugPrint(
      '$_tag ── BEGIN ── key=${message.messageKey} '
      'source=${message.source} sender=${message.sender}',
    );

    final Stage1Result s1 = _stage1.process(message);
    final Stage2Result s2 = await _stage2.check(s1);

    if (s2.isKnownSafe) {
      debugPrint('$_tag ✓ Stage 2 exit — URL trusted → inbox');
      return _buildTrustedResult(message: message, stage2: s2);
    }

    if (!s2.hasUrl) {
      debugPrint('$_tag ✓ Stage 2 exit — no URL → inbox');
      return _buildNoUrlAllowResult(message: message);
    }

    final Stage3Result s3 = await _stage3.runInference(s1.body);
    final Stage4Result s4 = await _stage4.calculate(s3);
    final DetectionResultModel result = await _stage5.route(
      message: message,
      stage2: s2,
      stage3: s3,
      stage4: s4,
    );

    debugPrint(
      '$_tag ── END ── decision=${result.decision} '
      'probability=${result.riskScore.toStringAsFixed(3)} '
      '→ ${result.shouldQuarantine ? "Quarantine Vault" : "Inbox"}',
    );

    return result;
  }

  /// Builds the early-exit result when every URL is trusted.
  DetectionResultModel _buildTrustedResult({
    required ScreenedMessageModel message,
    required Stage2Result stage2,
  }) {
    return DetectionResultModel(
      messageKey: message.messageKey,
      hasUrl: stage2.hasUrl,
      extractedUrls: stage2.extractedUrls,
      primaryUrl: stage2.primaryUrl,
      primaryDomain: stage2.primaryDomain,
      trustedMatch: true,
      mlInvoked: false,
      rawLogits: const <double>[],
      riskScore: 0.0,
      quarantineThreshold: OutputRouterStage.quarantineThreshold,
      decision: DetectionDecision.allowTrusted,
      reason: 'All URLs matched the local trusted-domain allowlist.',
      explanations: <String>[
        if (stage2.primaryDomain != null)
          'Domain "${stage2.primaryDomain}" is in the trusted allowlist.',
      ],
      needsRescan: false,
      heuristicScore: 0.0,
      modelScore: null,
      riskLevel: 'safe',
      detectionSource: 'allowlist',
      pipelineStage: 'stage_2_heuristic',
    );
  }

  /// Builds the early-exit result when no URL is present.
  DetectionResultModel _buildNoUrlAllowResult({
    required ScreenedMessageModel message,
  }) {
    return DetectionResultModel(
      messageKey: message.messageKey,
      hasUrl: false,
      extractedUrls: const <String>[],
      primaryUrl: null,
      primaryDomain: null,
      trustedMatch: false,
      mlInvoked: false,
      rawLogits: const <double>[],
      riskScore: 0.0,
      quarantineThreshold: OutputRouterStage.quarantineThreshold,
      decision: DetectionDecision.noUrlAllow,
      reason: 'No URL detected — message allowed without model inference.',
      explanations: const <String>[
        'Message contains no URL, so it was routed to the inbox.',
      ],
      needsRescan: false,
      heuristicScore: 0.0,
      modelScore: null,
      riskLevel: 'safe',
      detectionSource: 'no_url_heuristic',
      pipelineStage: 'stage_2_no_url_allow',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STAGE 1 — MESSAGE BUFFER STAGE
//
// Entry point of the pipeline. Receives ALL messages (SMS + online chat),
// normalizes the body, and forwards every message to Stage 2 without
// filtering or routing decisions.
// ─────────────────────────────────────────────────────────────────────────────

/// Stage 1: trims and normalizes the incoming message before URL checks.
class MessageBufferStage {
  /// Produces the normalized body/source pair consumed by Stage 2.
  Stage1Result process(ScreenedMessageModel message) {
    final String body = message.body.trim();
    final String source = message.source.trim().toLowerCase();
    return Stage1Result(body: body, source: source);
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// PUBLIC ENTRY POINT — SmishingPipelineService
//
// The single object the rest of the app imports and calls. Never touch
// individual pipeline stages directly — use this service instead.
//
//  quickScan(message)          — signals that a full scan is needed (SMS async)
//  deepScan(message)           — full 5-stage pipeline, always definitive
//  enqueue(message, priority)  — background FIFO queue with cooldown pacing
// ═══════════════════════════════════════════════════════════════════════════════

/// Queue priority used by the public pipeline service.
enum ScanPriority {
  high, // freshly received SMS — jumps to front of queue
  legacy, // inbox backfill — processed in order
}

/// Lightweight response used when SMS handling must return immediately.
class QuickScanVerdict {
  const QuickScanVerdict._({required this.status, this.result, this.domain});

  const QuickScanVerdict.safe(DetectionResultModel result)
      : this._(status: SafetyStatus.safe, result: result);

  const QuickScanVerdict.scanning({String? domain})
      : this._(status: SafetyStatus.scanning, domain: domain);

  final SafetyStatus status;
  final DetectionResultModel? result;
  final String? domain;
}

/// Public singleton used by the rest of the app to scan messages.
///
/// It handles initialization, duplicate in-flight scans, cached results, and
/// the background FIFO queue used for legacy inbox backfill.
class SmishingPipelineService {
  SmishingPipelineService._internal();

  static final SmishingPipelineService _instance =
      SmishingPipelineService._internal();
  factory SmishingPipelineService() => _instance;

  static const int _legacyBatchSize = 5;
  static const Duration _legacyCooldown = Duration(seconds: 5);

  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final SmishingPipeline _pipeline = SmishingPipeline();

  final ListQueue<_QueuedScanTask> _queue = ListQueue<_QueuedScanTask>();
  final Map<String, Future<DetectionResultModel>> _inFlightDeepScans =
      <String, Future<DetectionResultModel>>{};
  bool _workerActive = false;
  int _legacyProcessedInWindow = 0;
  Completer<void>? _cooldownInterruption;

  /// Initializes storage used by scans and cached-result lookups.
  Future<void> initialize() async {
    await _repository.initialize();
  }

  /// All messages must go through the full pipeline (Buffer → Heuristic Layer
  /// → DistilBERT → Probability Calculation → Routing). This method exists
  /// only so the SMS handler can save the message to storage immediately and
  /// enqueue the full scan asynchronously — it never short-circuits the pipeline.
  /// Returns a scanning verdict so callers can enqueue deep scanning async.
  Future<QuickScanVerdict> quickScan(ScreenedMessageModel message) async {
    return const QuickScanVerdict.scanning(domain: null);
  }

  /// Runs or reuses the definitive five-stage scan for one message.
  Future<DetectionResultModel> deepScan(ScreenedMessageModel message) async {
    final String key = _scanKey(message);
    final Future<DetectionResultModel>? inFlight = _inFlightDeepScans[key];
    if (inFlight != null) {
      debugPrint('[SmishingPipelineService] Reusing in-flight scan key=$key');
      return inFlight;
    }

    final Future<DetectionResultModel> scan = () async {
      final DetectionResultModel? cached =
          await _repository.getScreeningResultByMessageKey(message.messageKey);
      if (cached != null && !cached.needsRescan) {
        debugPrint(
          '[SmishingPipelineService] Reusing cached scan key=${message.messageKey}',
        );
        return cached;
      }

      await _pipeline.initialize();
      return _pipeline.run(message);
    }();

    _inFlightDeepScans[key] = scan;
    try {
      return await scan;
    } finally {
      if (identical(_inFlightDeepScans[key], scan)) {
        _inFlightDeepScans.remove(key);
      }
    }
  }

  /// Adds a scan task to the background queue and starts the worker if needed.
  void enqueue({
    required ScreenedMessageModel message,
    required ScanPriority priority,
    required Future<void> Function(DetectionResultModel result) onResult,
  }) {
    final String key = _scanKey(message);
    _queue.removeWhere((_QueuedScanTask queued) => queued.scanKey == key);
    final _QueuedScanTask task = _QueuedScanTask(
      message: message,
      priority: priority,
      scanKey: key,
      onResult: onResult,
    );

    if (priority == ScanPriority.high) {
      _queue.addFirst(task);
      _cooldownInterruption?.complete();
      _cooldownInterruption = null;
    } else {
      _queue.addLast(task);
    }

    unawaited(_drainQueue());
  }

  /// Processes queued scans, throttling legacy backfill after each batch.
  Future<void> _drainQueue() async {
    if (_workerActive) return;
    _workerActive = true;

    try {
      while (_queue.isNotEmpty) {
        final _QueuedScanTask task = _queue.removeFirst();
        final DetectionResultModel result = await deepScan(task.message);
        await task.onResult(result);

        if (task.priority == ScanPriority.high) {
          _legacyProcessedInWindow = 0;
          continue;
        }

        _legacyProcessedInWindow++;
        if (_legacyProcessedInWindow < _legacyBatchSize) continue;

        _legacyProcessedInWindow = 0;
        _cooldownInterruption = Completer<void>();
        await Future.any(<Future<void>>[
          Future<void>.delayed(_legacyCooldown),
          _cooldownInterruption!.future,
        ]);
        _cooldownInterruption = null;
      }
    } finally {
      _workerActive = false;
    }
  }

  /// Builds a stable key for de-duplication even when messageKey is missing.
  String _scanKey(ScreenedMessageModel message) {
    final String messageKey = message.messageKey.trim();
    if (messageKey.isNotEmpty) return '${message.source}:$messageKey';
    return '${message.source}:${message.sender}:${message.timestampMs}:'
        '${LocalDetectionRepository.computeBodyHash(message.body)}';
  }
}

/// Internal queue item containing the scan request and completion callback.
class _QueuedScanTask {
  const _QueuedScanTask({
    required this.message,
    required this.priority,
    required this.scanKey,
    required this.onResult,
  });

  final ScreenedMessageModel message;
  final ScanPriority priority;
  final String scanKey;
  final Future<void> Function(DetectionResultModel result) onResult;
}
