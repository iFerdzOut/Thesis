import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../models/detection_result_model.dart';
import '../models/safety_status.dart';
import '../models/screened_message_model.dart';
import 'local_detection_repository.dart';
import 'risk_scoring_service.dart';
import 'smishing_inference_isolate_service.dart';
import 'smishing_model_service.dart';
import 'trusted_domain_service.dart';
import 'url_extraction_service.dart';

enum SmishingQueuePriority {
  high,
  legacy,
}

class SmishingQuickVerdict {
  const SmishingQuickVerdict._({
    required this.status,
    this.result,
    this.domain,
  });

  const SmishingQuickVerdict.safe(DetectionResultModel result)
      : this._(status: SafetyStatus.safe, result: result);

  const SmishingQuickVerdict.scanning({String? domain})
      : this._(status: SafetyStatus.scanning, domain: domain);

  final SafetyStatus status;
  final DetectionResultModel? result;
  final String? domain;
}

class SmishingDetectionPipelineService {
  SmishingDetectionPipelineService._internal();

  static final SmishingDetectionPipelineService _instance =
      SmishingDetectionPipelineService._internal();
  factory SmishingDetectionPipelineService() => _instance;

  static final RegExp _urlRegex = RegExp(
    r'(?:(?:https?|ftp):\/\/)?[\w/\-?=%.]+\.[\w/\-?=%.]+',
    caseSensitive: false,
  );
  static const int _legacyBatchSize = 5;
  static const Duration _legacyCooldown = Duration(seconds: 7);

  final UrlExtractionService _urlExtractionService = UrlExtractionService();
  final TrustedDomainService _trustedDomainService = TrustedDomainService();
  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final RiskScoringService _riskScoringService = RiskScoringService();
  final SmishingInferenceIsolateService _inferenceWorker =
      SmishingInferenceIsolateService();

  final ListQueue<_QueuedScanTask> _queue = ListQueue<_QueuedScanTask>();
  bool _workerActive = false;
  int _legacyProcessedInWindow = 0;
  Completer<void>? _cooldownInterruption;

  Future<void> initialize() async {
    await _repository.initialize();
    await _trustedDomainService.initialize();
  }

  Future<SmishingQuickVerdict> quickScan(
    ScreenedMessageModel message,
  ) async {
    await initialize();
    final String body = message.body.trim();
    final double threshold = await _riskScoringService.quarantineThreshold;
    if (body.isEmpty || !_urlRegex.hasMatch(body)) {
      final DetectionResultModel result = DetectionResultModel(
        messageKey: message.messageKey,
        hasUrl: false,
        extractedUrls: const <String>[],
        primaryUrl: null,
        primaryDomain: null,
        trustedMatch: true,
        mlInvoked: false,
        rawLogits: const <double>[],
        riskScore: 0,
        warningThreshold: threshold,
        quarantineThreshold: threshold,
        decision: DetectionDecision.noUrlAllow,
        reason: 'No URL detected by the fast path.',
        explanations: const <String>[
          'The fast-path regex did not detect any URL.',
        ],
        needsRescan: false,
        heuristicScore: 0,
        modelScore: null,
        riskLevel: 'safe',
        detectionSource: 'fast_path_regex',
        pipelineStage: 'fast_path',
      );
      await _repository.saveScreeningResult(result: result, message: message);
      return SmishingQuickVerdict.safe(result);
    }

    final List<String> urls = _urlExtractionService.extractUrls(body);
    final String? primaryUrl =
        urls.isEmpty ? _urlRegex.stringMatch(body) : urls.first;
    final String? domain = primaryUrl == null
        ? null
        : _urlExtractionService.extractDomain(primaryUrl);
    if (domain != null && domain.trim().isNotEmpty) {
      final bool trusted = await _trustedDomainService.isUrlTrusted(domain);
      if (trusted) {
        final DetectionResultModel result = DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: true,
          extractedUrls:
              urls.isEmpty && primaryUrl != null ? <String>[primaryUrl] : urls,
          primaryUrl: primaryUrl,
          primaryDomain: domain,
          trustedMatch: true,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0,
          warningThreshold: threshold,
          quarantineThreshold: threshold,
          decision: DetectionDecision.allowTrusted,
          reason: 'Domain matched the local trusted whitelist.',
          explanations: const <String>[
            'The URL domain is allowlisted in local SQLite storage.',
          ],
          needsRescan: false,
          heuristicScore: 0,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'heuristic_whitelist',
          pipelineStage: 'allowlist',
        );
        await _repository.saveScreeningResult(result: result, message: message);
        return SmishingQuickVerdict.safe(result);
      }
    }

    return SmishingQuickVerdict.scanning(domain: domain);
  }

  Future<DetectionResultModel> deepScan(ScreenedMessageModel message) async {
    await initialize();
    final List<String> urls = _urlExtractionService.extractUrls(message.body);
    final String? primaryUrl = urls.isEmpty ? null : urls.first;
    final String? domain = primaryUrl == null
        ? null
        : _urlExtractionService.extractDomain(primaryUrl);
    final String normalized = _normalize(message.body);
    final SmishingModelOutput? output =
        await _inferenceWorker.runInference(normalized);
    final double threshold = await _riskScoringService.quarantineThreshold;
    final double modelScore = output == null || output.logits.isEmpty
        ? 0.0
        : await _riskScoringService.scoreFromLogits(
            output.logits,
            positiveIndex: output.positiveIndex,
          );
    final double heuristicScore = _heuristicRisk(message.body, domain: domain);
    final double finalScore =
        math.max(modelScore, heuristicScore).clamp(0.0, 1.0);
    final bool malicious = finalScore >= threshold;
    final DetectionResultModel result = DetectionResultModel(
      messageKey: message.messageKey,
      hasUrl: urls.isNotEmpty,
      extractedUrls: urls,
      primaryUrl: primaryUrl,
      primaryDomain: domain,
      trustedMatch: false,
      mlInvoked: output != null,
      rawLogits: output?.logits ?? const <double>[],
      riskScore: finalScore,
      warningThreshold: threshold,
      quarantineThreshold: threshold,
      decision: malicious
          ? DetectionDecision.quarantineHighRisk
          : DetectionDecision.allowLowRisk,
      reason: malicious
          ? 'The link was classified as malicious.'
          : 'The link stayed below the malicious threshold.',
      explanations: <String>[
        if (domain != null && domain.isNotEmpty) 'Untrusted domain: $domain.',
        if (output != null) 'On-device AI inference completed in the worker.',
        if (_looksShortened(domain))
          'The domain appears to use a shortened redirect.',
        if (_looksCredentialHarvest(message.body))
          'The message mixes a link with credential or urgency language.',
      ],
      needsRescan: false,
      heuristicScore: heuristicScore,
      modelScore: output == null ? null : modelScore,
      riskLevel: malicious ? 'high' : 'safe',
      detectionSource: 'tiered_worker_pipeline',
      pipelineStage: 'ai_inference',
    );
    await _repository.saveScreeningResult(result: result, message: message);
    return result;
  }

  void enqueue({
    required ScreenedMessageModel message,
    required SmishingQueuePriority priority,
    required Future<void> Function(DetectionResultModel result) onResult,
  }) {
    final _QueuedScanTask task = _QueuedScanTask(
      message: message,
      priority: priority,
      onResult: onResult,
    );
    if (priority == SmishingQueuePriority.high) {
      _queue.addFirst(task);
      _cooldownInterruption?.complete();
      _cooldownInterruption = null;
    } else {
      _queue.addLast(task);
    }
    unawaited(_drainQueue());
  }

  Future<void> _drainQueue() async {
    if (_workerActive) {
      return;
    }
    _workerActive = true;
    try {
      while (_queue.isNotEmpty) {
        final _QueuedScanTask task = _queue.removeFirst();
        final DetectionResultModel result = await deepScan(task.message);
        await task.onResult(result);

        if (task.priority == SmishingQueuePriority.high) {
          _legacyProcessedInWindow = 0;
          continue;
        }

        _legacyProcessedInWindow++;
        if (_legacyProcessedInWindow < _legacyBatchSize) {
          continue;
        }

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

  bool _looksCredentialHarvest(String body) {
    final String lower = body.toLowerCase();
    const List<String> riskyPhrases = <String>[
      'verify',
      'otp',
      'pin',
      'password',
      'urgent',
      'suspended',
      'locked',
      'claim',
    ];
    return riskyPhrases.any(lower.contains);
  }

  bool _looksShortened(String? domain) {
    const Set<String> shorteners = <String>{
      'bit.ly',
      'tinyurl.com',
      'rb.gy',
      't.ly',
      'tiny.one',
      'cutt.ly',
    };
    return shorteners.contains(domain?.toLowerCase().trim());
  }

  double _heuristicRisk(String body, {String? domain}) {
    double score = 0.18;
    if (_looksShortened(domain)) {
      score += 0.14;
    }
    if (_looksCredentialHarvest(body)) {
      score += 0.2;
    }
    final String lower = body.toLowerCase();
    if (lower.contains('http') ||
        lower.contains('www') ||
        lower.contains('.ly')) {
      score += 0.06;
    }
    if (domain != null && RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(domain)) {
      score += 0.2;
    }
    return score.clamp(0.0, 1.0);
  }

  String _normalize(String body) {
    return body.trim().replaceAll(RegExp(r'\s+'), ' ');
  }
}

class _QueuedScanTask {
  const _QueuedScanTask({
    required this.message,
    required this.priority,
    required this.onResult,
  });

  final ScreenedMessageModel message;
  final SmishingQueuePriority priority;
  final Future<void> Function(DetectionResultModel result) onResult;
}
