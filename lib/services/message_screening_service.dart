import 'dart:math' as math;

import '../models/detection_result_model.dart';
import '../models/screened_message_model.dart';
import 'local_detection_repository.dart';
import 'otp_whitelist_service.dart';
import 'risk_scoring_service.dart';
import 'smishing_model_service.dart';
import 'trusted_domain_service.dart';
import 'url_extraction_service.dart';

class MessageScreeningService {
  MessageScreeningService._internal();

  static final MessageScreeningService instance =
      MessageScreeningService._internal();
  factory MessageScreeningService() => instance;

  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final UrlExtractionService _urlExtractionService = UrlExtractionService();
  final TrustedDomainService _trustedDomainService = TrustedDomainService();
  final SmishingModelService _modelService = SmishingModelService();
  final RiskScoringService _riskScoringService = RiskScoringService();

  static const Set<String> _trustedSenderIds = <String>{
    'GCASH',
    'G CASH',
    'GCASHOTP',
    'GCREDIT',
    'GGIVES',
    'SMART',
    'SMARTSMS',
    'SMARTCOMM',
    'SMARTCOMMUNICATIONS',
    'TNT',
    'GLOBE',
    'GLOBEATHOME',
    'GLOBEONE',
    'MAYA',
    'PAYMAYA',
    'MAYABANK',
    'BDO',
    'BDOUNIBANK',
    'BDOONLINE',
    'BPI',
    'BPIONLINE',
    'UNIONBANK',
    'UBP',
    'METROBANK',
    'MBTC',
    'PNB',
    'LANDBANK',
    'LBP',
    'RCBC',
    'RCBCPULZ',
    'SECBANK',
    'SECURITYBANK',
    'CHINABANK',
    'CHINABK',
    'EASTWEST',
    'EWBC',
    'PSBANK',
    'AUB',
    'MAYBANK',
    'CIMB',
    'CIMBBANK',
    'SEABANK',
    'GOTYME',
    'GO TYME',
    'TONIK',
    'KOMO',
    'KOMOBYEB',
    'DISKARTECH',
    'ROBINSONSBANK',
    'BANKCOM',
    'DBP',
    'OFBANK',
    'OWWBANK',
    'MERALCO',
    'MAYAOTP',
    'DITO',
    'DITOTELECOMMUNITY',
    'PLDT',
    'PLDTHOME',
    'CONVERGE',
    'MERALCOONLINE',
    'MWSI',
    'MAYNILAD',
    'MANILAWATER',
    'NOREPLYGCASH',
    'NOREPLYMAYA',
  };

  Future<void> warmUp() async {
    await _repository.initialize();
    await _trustedDomainService.initialize();
  }

  bool get isModelLoaded => _modelService.isModelLoaded;

  Future<void> loadModel() => _modelService.loadModel();

  Future<void> releaseHeavyResources() => _modelService.releaseModel();

  Future<DetectionResultModel> screenMessage(
    ScreenedMessageModel message, {
    bool forceRescore = false,
  }) async {
    await _repository.initialize();
    final String body = message.body.trim();
    final double warningThreshold = await _riskScoringService.warningThreshold;
    final double quarantineThreshold =
        await _riskScoringService.quarantineThreshold;

    if (body.isEmpty) {
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: false,
          extractedUrls: const <String>[],
          primaryUrl: null,
          primaryDomain: null,
          trustedMatch: false,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.0,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.noUrlAllow,
          reason: 'The message is empty.',
          explanations: const <String>['The message is empty.'],
          needsRescan: false,
          heuristicScore: 0.0,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'empty_message',
          pipelineStage: 'buffer',
        ),
      );
    }

    if (!forceRescore) {
      final DetectionResultModel? cached =
          await _repository.getScreeningResultByMessageKey(message.messageKey);
      if (cached != null) {
        return cached;
      }
    }

    if (_isStrictSmsSource(message.source)) {
      return _screenSmsDiagramMessage(
        message: message,
        body: body,
        warningThreshold: warningThreshold,
        quarantineThreshold: quarantineThreshold,
      );
    }

    if (OtpWhitelistService.isOtp(message.sender, body)) {
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: false,
          extractedUrls: const <String>[],
          primaryUrl: null,
          primaryDomain: null,
          trustedMatch: true,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.02,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.allowTrusted,
          reason: 'OTP whitelist matched a trusted sender and verification pattern.',
          explanations: const <String>[
            'OTP-like message matched the trusted verification whitelist.',
          ],
          needsRescan: false,
          heuristicScore: 0.02,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'otp_whitelist',
          pipelineStage: 'allowlist',
        ),
      );
    }

    final List<String> extractedUrls = _urlExtractionService.extractUrls(body);
    final bool trustedSender = _isTrustedSender(message.sender);
    final bool? trustedUrls =
        await _trustedDomainService.areAllUrlsTrusted(extractedUrls);
    final String normalized = _normalizeForScoring(body);

    if (trustedSender && trustedUrls != false) {
      final List<String> explanations = _uniqueReasons(<String>[
        'The sender matches a trusted allowlisted sender ID.',
        if (trustedUrls == true)
          'All detected links match trusted allowlisted domains.'
        else
          'No unknown links were found in the message.',
      ]);
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: extractedUrls.isNotEmpty,
          extractedUrls: extractedUrls,
          primaryUrl: extractedUrls.isEmpty ? null : extractedUrls.first,
          primaryDomain: extractedUrls.isEmpty
              ? null
              : _urlExtractionService.extractDomain(extractedUrls.first),
          trustedMatch: true,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.01,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.allowTrusted,
          reason: explanations.first,
          explanations: explanations,
          needsRescan: false,
          heuristicScore: 0.01,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'allowlist_sender',
          pipelineStage: 'allowlist',
        ),
      );
    }

    if (trustedUrls == true) {
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: true,
          extractedUrls: extractedUrls,
          primaryUrl: extractedUrls.first,
          primaryDomain: _urlExtractionService.extractDomain(extractedUrls.first),
          trustedMatch: true,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.01,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.allowTrusted,
          reason: 'All detected links match trusted allowlisted domains.',
          explanations: const <String>[
            'All detected links match trusted allowlisted domains.',
          ],
          needsRescan: false,
          heuristicScore: 0.01,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'allowlist_url',
          pipelineStage: 'allowlist',
        ),
      );
    }

    if (extractedUrls.isNotEmpty) {
      final SmishingModelOutput? modelOutput =
          await _modelService.runInference(normalized);
      final Map<String, dynamic> primaryUrlSignal =
          await _pickPrimaryUrlSignal(extractedUrls);

      if (modelOutput != null && modelOutput.logits.isNotEmpty) {
        final double riskScore = await _riskScoringService.scoreFromLogits(
          modelOutput.logits,
          positiveIndex: modelOutput.positiveIndex,
        );
        final String decision = await _riskScoringService.decisionFor(
          hasUrl: true,
          trustedMatch: false,
          modelError: false,
          riskScore: riskScore,
        );
        final String riskLevel =
            await _riskScoringService.levelFromScore(riskScore);
        final _SignalBundle urlSignals = _scoreUrlSignals(body);
        final List<String> explanations = _uniqueReasons(<String>[
          'The message contains an unknown or untrusted link.',
          'The DistilBERT model was used to score the message risk.',
          ...urlSignals.reasons,
          if (decision == DetectionDecision.quarantineHighRisk)
            'The final smishing probability crossed the quarantine threshold.',
        ]);
        return _persistAndReturn(
          message: message,
          result: DetectionResultModel(
            messageKey: message.messageKey,
            hasUrl: true,
            extractedUrls: extractedUrls,
            primaryUrl: primaryUrlSignal['url']?.toString(),
            primaryDomain: primaryUrlSignal['domain']?.toString(),
            trustedMatch: false,
            mlInvoked: true,
            rawLogits: modelOutput.logits,
            riskScore: riskScore,
            warningThreshold: warningThreshold,
            quarantineThreshold: quarantineThreshold,
            decision: decision,
            reason: explanations.first,
            explanations: explanations,
            needsRescan: false,
            heuristicScore: 0.0,
            modelScore: riskScore,
            riskLevel: riskLevel,
            detectionSource: 'distilbert_url_pipeline',
            pipelineStage: 'distilbert',
          ),
        );
      }

      final DetectionResultModel fallback = await _buildHeuristicResult(
        message: message,
        normalized: normalized,
        extractedUrls: extractedUrls,
        modelError: true,
      );
      return _persistAndReturn(
        message: message,
        result: fallback.copyWith(
          decision: DetectionDecision.modelErrorFallback,
          reason:
              'The model was unavailable, so the message was allowed and queued for rescan.',
          needsRescan: true,
          detectionSource: 'heuristic_url_fallback',
          pipelineStage: 'heuristic_fallback',
        ),
      );
    }

    final DetectionResultModel noUrlResult = await _buildHeuristicResult(
      message: message,
      normalized: normalized,
      extractedUrls: extractedUrls,
      modelError: false,
    );
    return _persistAndReturn(message: message, result: noUrlResult);
  }

  bool _isStrictSmsSource(String source) {
    final normalized = source.trim().toLowerCase();
    return normalized == 'sms' || normalized == 'sms_limited';
  }

  Future<DetectionResultModel> _screenSmsDiagramMessage({
    required ScreenedMessageModel message,
    required String body,
    required double warningThreshold,
    required double quarantineThreshold,
  }) async {
    final List<String> extractedUrls = _urlExtractionService.extractUrls(body);

    if (OtpWhitelistService.isOtp(message.sender, body) &&
        extractedUrls.isEmpty) {
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: false,
          extractedUrls: const <String>[],
          primaryUrl: null,
          primaryDomain: null,
          trustedMatch: true,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.01,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.allowTrusted,
          reason:
              'OTP whitelist matched a trusted verification message without a URL.',
          explanations: const <String>[
            'OTP-like message matched the trusted verification whitelist.',
          ],
          needsRescan: false,
          heuristicScore: 0.0,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'otp_whitelist',
          pipelineStage: 'buffer',
        ),
      );
    }

    if (extractedUrls.isEmpty) {
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: false,
          extractedUrls: const <String>[],
          primaryUrl: null,
          primaryDomain: null,
          trustedMatch: false,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.04,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.noUrlAllow,
          reason:
              'No URL was found, so the SMS was treated as low risk and allowed to the inbox.',
          explanations: const <String>[
            'No URL was found in the message.',
            'The strict SMS pipeline only escalates unknown-link messages to the model.',
          ],
          needsRescan: false,
          heuristicScore: 0.0,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'sms_no_url_allow',
          pipelineStage: 'buffer',
        ),
      );
    }

    final bool? trustedUrls =
        await _trustedDomainService.areAllUrlsTrusted(extractedUrls);
    final Map<String, dynamic> primaryUrlSignal =
        await _pickPrimaryUrlSignal(extractedUrls);
    final String primaryUrl = primaryUrlSignal['url']?.toString().trim().isNotEmpty ==
            true
        ? primaryUrlSignal['url'].toString().trim()
        : extractedUrls.first;
    final String primaryDomain =
        primaryUrlSignal['domain']?.toString().trim().isNotEmpty == true
            ? primaryUrlSignal['domain'].toString().trim()
            : _urlExtractionService.extractDomain(primaryUrl);

    if (trustedUrls == true) {
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: true,
          extractedUrls: extractedUrls,
          primaryUrl: primaryUrl,
          primaryDomain: primaryDomain,
          trustedMatch: true,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.01,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.allowTrusted,
          reason: 'All detected links match trusted allowlisted domains.',
          explanations: const <String>[
            'A URL was found in the message.',
            'All detected links match trusted allowlisted domains.',
          ],
          needsRescan: false,
          heuristicScore: 0.0,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'allowlist_url',
          pipelineStage: 'allowlist',
        ),
      );
    }

    final SmishingModelOutput? modelOutput =
        await _modelService.runInference(_normalizeForScoring(body));
    if (modelOutput == null || modelOutput.logits.isEmpty) {
      return _persistAndReturn(
        message: message,
        result: DetectionResultModel(
          messageKey: message.messageKey,
          hasUrl: true,
          extractedUrls: extractedUrls,
          primaryUrl: primaryUrl,
          primaryDomain: primaryDomain,
          trustedMatch: false,
          mlInvoked: false,
          rawLogits: const <double>[],
          riskScore: 0.12,
          warningThreshold: warningThreshold,
          quarantineThreshold: quarantineThreshold,
          decision: DetectionDecision.modelErrorFallback,
          reason:
              'A URL was found, but the on-device model was unavailable, so the SMS was allowed and queued for rescan.',
          explanations: const <String>[
            'A URL was found in the message.',
            'The link is not on the trusted-domain allowlist.',
            'The on-device DistilBERT model was unavailable, so the message was allowed as a fail-safe fallback.',
          ],
          needsRescan: true,
          heuristicScore: 0.0,
          modelScore: null,
          riskLevel: 'safe',
          detectionSource: 'distilbert_unavailable',
          pipelineStage: 'distilbert',
        ),
      );
    }

    final double riskScore = await _riskScoringService.scoreFromLogits(
      modelOutput.logits,
      positiveIndex: modelOutput.positiveIndex,
    );
    final String decision = await _riskScoringService.decisionFor(
      hasUrl: true,
      trustedMatch: false,
      modelError: false,
      riskScore: riskScore,
    );
    final String riskLevel =
        await _riskScoringService.levelFromScore(riskScore);
    final List<String> explanations = _uniqueReasons(<String>[
      'A URL was found in the message.',
      'The link is not on the trusted-domain allowlist.',
      'The on-device DistilBERT model scored the full SMS content.',
      if (decision == DetectionDecision.quarantineHighRisk)
        'The smishing probability crossed the quarantine threshold.'
      else
        'The smishing probability stayed below the quarantine threshold.',
    ]);

    return _persistAndReturn(
      message: message,
      result: DetectionResultModel(
        messageKey: message.messageKey,
        hasUrl: true,
        extractedUrls: extractedUrls,
        primaryUrl: primaryUrl,
        primaryDomain: primaryDomain,
        trustedMatch: false,
        mlInvoked: true,
        rawLogits: modelOutput.logits,
        riskScore: riskScore,
        warningThreshold: warningThreshold,
        quarantineThreshold: quarantineThreshold,
        decision: decision,
        reason: explanations.first,
        explanations: explanations,
        needsRescan: false,
        heuristicScore: 0.0,
        modelScore: riskScore,
        riskLevel: riskLevel,
        detectionSource: 'distilbert_url_pipeline',
        pipelineStage: 'distilbert',
      ),
    );
  }

  Future<DetectionResultModel> _buildHeuristicResult({
    required ScreenedMessageModel message,
    required String normalized,
    required List<String> extractedUrls,
    required bool modelError,
  }) async {
    double heuristicScore = extractedUrls.isNotEmpty ? 0.18 : 0.04;
    final double warningThreshold = await _riskScoringService.warningThreshold;
    final double quarantineThreshold =
        await _riskScoringService.quarantineThreshold;
    final List<String> explanations = <String>[
      if (extractedUrls.isNotEmpty)
        modelError
            ? 'The model was unavailable, so the fallback heuristic rules were used.'
            : 'The message contains a URL, so fallback heuristic rules were applied.'
      else
        'No URL was found, so the fallback heuristic rules were used.',
    ];

    final _SignalBundle urlSignals = _scoreUrlSignals(message.body);
    heuristicScore += urlSignals.scoreDelta;
    explanations.addAll(urlSignals.reasons);

    final _SignalBundle senderSignals = _scoreSenderSignals(message.sender);
    heuristicScore += senderSignals.scoreDelta;
    explanations.addAll(senderSignals.reasons);

    final _SignalBundle contentSignals = _scoreContentSignals(
      normalized,
      hasUrl: extractedUrls.isNotEmpty,
    );
    heuristicScore += contentSignals.scoreDelta;
    explanations.addAll(contentSignals.reasons);

    final _SignalBundle comboSignals =
        _scoreCombinationSignals(normalized, message.body);
    heuristicScore += comboSignals.scoreDelta;
    explanations.addAll(comboSignals.reasons);

    final double clamped = heuristicScore.clamp(0.0, 1.0).toDouble();
    final String level = await _riskScoringService.levelFromScore(clamped);
    final String decision = modelError
        ? DetectionDecision.modelErrorFallback
        : await _riskScoringService.decisionFor(
            hasUrl: extractedUrls.isNotEmpty,
            trustedMatch: false,
            modelError: false,
            riskScore: clamped,
          );

    return DetectionResultModel(
      messageKey: message.messageKey,
      hasUrl: extractedUrls.isNotEmpty,
      extractedUrls: extractedUrls,
      primaryUrl: extractedUrls.isEmpty ? null : extractedUrls.first,
      primaryDomain: extractedUrls.isEmpty
          ? null
          : _urlExtractionService.extractDomain(extractedUrls.first),
      trustedMatch: false,
      mlInvoked: false,
      rawLogits: const <double>[],
      riskScore: clamped,
      warningThreshold: warningThreshold,
      quarantineThreshold: quarantineThreshold,
      decision: decision,
      reason: _uniqueReasons(explanations).first,
      explanations: _uniqueReasons(explanations),
      needsRescan: modelError,
      heuristicScore: clamped,
      modelScore: null,
      riskLevel: level,
      detectionSource: extractedUrls.isNotEmpty
          ? 'heuristic_url_fallback'
          : 'heuristic_text_fallback',
      pipelineStage: 'heuristic_fallback',
    );
  }

  Future<DetectionResultModel> _persistAndReturn({
    required ScreenedMessageModel message,
    required DetectionResultModel result,
  }) async {
    await _repository.saveScreeningResult(result: result, message: message);
    return result;
  }

  Future<Map<String, dynamic>> _pickPrimaryUrlSignal(List<String> urls) async {
    final List<Map<String, dynamic>> analyses =
        await _trustedDomainService.analyzeUrls(urls);
    analyses.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final double aWeight = _urlRiskWeight(a);
      final double bWeight = _urlRiskWeight(b);
      return bWeight.compareTo(aWeight);
    });
    return analyses.isEmpty ? <String, dynamic>{} : analyses.first;
  }

  double _urlRiskWeight(Map<String, dynamic> entry) {
    final String domain = entry['domain']?.toString() ?? '';
    final bool trusted = entry['trusted'] == true;
    if (trusted) {
      return 0.0;
    }
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(domain)) {
      return 2.0;
    }
    const Set<String> shorteners = <String>{
      'bit.ly',
      'tinyurl.com',
      'cutt.ly',
      'goo.gl',
      't.ly',
      'tiny.one',
      'shorturl.at',
      'rb.gy',
    };
    if (shorteners.contains(domain)) {
      return 1.5;
    }
    return 1.0;
  }

  _SignalBundle _scoreUrlSignals(String rawText) {
    final List<String> urls = _urlExtractionService.extractUrls(rawText);
    if (urls.isEmpty) {
      final bool hintsLink = rawText.toLowerCase().contains('link');
      return _SignalBundle(
        scoreDelta: hintsLink ? 0.06 : 0.0,
        reasons: hintsLink
            ? const <String>[
                'The message asks you to follow a link without showing a clear trusted URL.',
              ]
            : const <String>[],
      );
    }

    var score = 0.0;
    final List<String> reasons = <String>[];
    final List<Map<String, dynamic>> analyses = urls
        .map((String url) => <String, dynamic>{
              'url': url,
              'domain': _urlExtractionService.extractDomain(url),
              'trusted': _trustedDomainService.isUrlTrustedCached(url),
            })
        .toList(growable: false);
    final int trustedCount =
        analyses.where((Map<String, dynamic> item) => item['trusted'] == true).length;
    final List<Map<String, dynamic>> riskyEntries = analyses
        .where((Map<String, dynamic> item) => item['trusted'] != true)
        .toList(growable: false);

    if (riskyEntries.isEmpty) {
      score -= 0.14;
      reasons.add('All detected links match trusted domains.');
    } else {
      score += math.min(0.48, math.max(0.22, 0.22 * riskyEntries.length));
      reasons.add(
        riskyEntries.length == 1
            ? 'A link points to an untrusted domain.'
            : 'Multiple links point to untrusted domains.',
      );
    }

    final bool containsShortener = riskyEntries.any((Map<String, dynamic> entry) {
      const Set<String> shorteners = <String>{
        'bit.ly',
        'tinyurl.com',
        'cutt.ly',
        'goo.gl',
        't.ly',
        'tiny.one',
        'shorturl.at',
        'rb.gy',
      };
      return shorteners.contains(entry['domain']?.toString() ?? '');
    });
    if (containsShortener) {
      score += 0.12;
      reasons.add('A shortened link hides the final destination.');
    }

    final bool containsIpUrl = riskyEntries.any((Map<String, dynamic> entry) {
      final String domain = entry['domain']?.toString() ?? '';
      return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(domain);
    });
    if (containsIpUrl) {
      score += 0.18;
      reasons.add('A link uses a raw IP address instead of a normal domain.');
    }

    final String lower = rawText.toLowerCase();
    if (lower.contains('hxxp') || lower.contains('[.]')) {
      score += 0.12;
      reasons.add('The link looks intentionally obfuscated.');
    }

    if (trustedCount > 0 && riskyEntries.isNotEmpty) {
      score += 0.05;
      reasons.add('Trusted-looking and untrusted links are mixed together.');
    }

    return _SignalBundle(scoreDelta: score, reasons: reasons);
  }

  _SignalBundle _scoreSenderSignals(String sender) {
    final String trimmed = sender.trim();
    if (trimmed.isEmpty) {
      return const _SignalBundle(
        scoreDelta: 0.05,
        reasons: <String>['The sender identity is missing or unclear.'],
      );
    }

    final String upper = trimmed.toUpperCase();
    final String canonical = _canonicalizeSenderId(trimmed);
    var score = 0.0;
    final List<String> reasons = <String>[];

    if (_trustedSenderIds.contains(upper) ||
        _trustedSenderIds.contains(canonical)) {
      return const _SignalBundle(
        scoreDelta: -0.18,
        reasons: <String>[
          'The sender matches a trusted branded sender ID.',
        ],
      );
    }

    if (RegExp(r'^\+?\d[\d\s-]{8,}$').hasMatch(trimmed)) {
      score += 0.04;
      reasons.add(
        'The SMS comes from a normal phone number instead of a branded sender ID.',
      );
    } else if (RegExp(r'^[A-Z0-9\s]{2,15}$').hasMatch(upper)) {
      score -= 0.04;
      reasons.add('The sender uses a stable branded sender ID.');
    } else {
      score += 0.06;
      reasons.add('The sender identity looks unusual for a legitimate service.');
    }

    return _SignalBundle(scoreDelta: score, reasons: reasons);
  }

  _SignalBundle _scoreContentSignals(String normalized, {required bool hasUrl}) {
    final List<_KeywordGroup> groups = <_KeywordGroup>[
      const _KeywordGroup(
        weight: 0.18,
        reason: 'The message pressures you to verify or restore an account.',
        patterns: <String>[
          'verify your account',
          'account suspended',
          'account locked',
          'restore access',
          'confirm your account',
          'confirm your identity',
          'update your account',
          'reactivate',
          'login immediately',
        ],
      ),
      _KeywordGroup(
        weight: hasUrl ? 0.08 : 0.04,
        reason: 'The message asks for financial or wallet action.',
        patterns: const <String>[
          'gcash',
          'maya',
          'bank',
          'bdo',
          'bpi',
          'unionbank',
          'wallet',
          'transfer',
          'claim your refund',
          'cash out',
        ],
      ),
      const _KeywordGroup(
        weight: 0.1,
        reason: 'The message uses urgency or fear to rush you.',
        patterns: <String>[
          'urgent',
          'immediately',
          'asap',
          'final warning',
          'act now',
          'expires today',
          'within 24 hours',
          'avoid suspension',
          'unauthorized',
          'security alert',
        ],
      ),
      _KeywordGroup(
        weight: hasUrl ? 0.08 : 0.02,
        reason: 'The message offers prize or reward bait.',
        patterns: const <String>[
          'claim',
          'prize',
          'winner',
          'raffle',
          'cashback',
          'free spins',
          'bonus',
          'reward',
          'nanalo',
          'ayuda',
          'voucher',
          'gift',
        ],
      ),
      _KeywordGroup(
        weight: hasUrl ? 0.24 : 0.12,
        reason: 'The message contains casino or gambling bait.',
        patterns: const <String>[
          'casino',
          'casino plus',
          'casinoplus',
          'gambling',
          'slot',
          'slots',
          'free spins',
          'jackpot',
          'roulette',
          'baccarat',
          'poker',
          'betting',
          'sportsbook',
          'sabong',
          'taya',
        ],
      ),
      const _KeywordGroup(
        weight: 0.16,
        reason: 'The message asks for secrets or one-time credentials.',
        patterns: <String>[
          'otp',
          'one time password',
          'password',
          'pin',
          'verification code',
          'security code',
        ],
      ),
    ];

    var score = 0.0;
    final List<String> reasons = <String>[];
    for (final _KeywordGroup group in groups) {
      if (group.matches(normalized)) {
        score += group.weight;
        reasons.add(group.reason);
      }
    }

    final int capsMatches =
        RegExp(r'\b[A-Z]{4,}\b').allMatches(normalized).length;
    if (capsMatches >= 3) {
      score += 0.06;
      reasons.add('The message uses repeated all-caps emphasis.');
    }

    if (RegExp(r'[!?]{3,}').hasMatch(normalized)) {
      score += 0.04;
      reasons.add('The message uses aggressive punctuation for pressure.');
    }

    return _SignalBundle(scoreDelta: score, reasons: reasons);
  }

  _SignalBundle _scoreCombinationSignals(String normalized, String rawText) {
    var score = 0.0;
    final List<String> reasons = <String>[];
    final String lower = normalized.toLowerCase();
    final bool hasUrl = _urlExtractionService.extractUrls(rawText).isNotEmpty;

    final bool asksForCredential =
        lower.contains('otp') ||
            lower.contains('password') ||
            lower.contains('pin') ||
            lower.contains('verification code');
    if (hasUrl && asksForCredential) {
      score += 0.18;
      reasons.add(
        'The message combines a link with a request for sensitive credentials.',
      );
    }

    final bool hasUrgency =
        lower.contains('urgent') ||
            lower.contains('immediately') ||
            lower.contains('final warning') ||
            lower.contains('expires');
    final bool hasAccountThreat =
        lower.contains('account suspended') ||
            lower.contains('account locked') ||
            lower.contains('security alert') ||
            lower.contains('unauthorized');
    if (hasUrgency && hasAccountThreat) {
      score += 0.12;
      reasons.add(
        'Urgency is paired with an account threat, a common smishing pattern.',
      );
    }

    if (!hasUrl && asksForCredential && (hasUrgency || hasAccountThreat)) {
      score += 0.18;
      reasons.add(
        'A credential request is paired with urgency or an account threat, which is highly suspicious.',
      );
    }

    final bool asksForReplyAction =
        lower.contains('reply') ||
            lower.contains('send back') ||
            lower.contains('text back') ||
            lower.contains('confirm now');
    if (!hasUrl && hasAccountThreat && asksForReplyAction) {
      score += 0.12;
      reasons.add(
        'The message pairs an account threat with a forced reply action.',
      );
    }

    final bool hasPrize =
        lower.contains('prize') ||
            lower.contains('reward') ||
            lower.contains('bonus');
    if (hasPrize && hasUrl) {
      score += 0.10;
      reasons.add('A reward offer is tied to a link click.');
    }

    final bool hasGambling =
        lower.contains('casino') ||
            lower.contains('gambling') ||
            lower.contains('slot') ||
            lower.contains('slots') ||
            lower.contains('free spins') ||
            lower.contains('jackpot') ||
            lower.contains('roulette') ||
            lower.contains('baccarat') ||
            lower.contains('poker') ||
            lower.contains('betting') ||
            lower.contains('sportsbook') ||
            lower.contains('sabong') ||
            lower.contains('taya');
    if (hasGambling && hasUrl) {
      score += 0.24;
      reasons.add('Casino or gambling bait is tied to a link click.');
    } else if (hasGambling && hasPrize) {
      score += 0.12;
      reasons.add('Casino or gambling bait is paired with a reward offer.');
    }

    final bool hasClaimOrTapAction =
        lower.contains('claim') ||
            lower.contains('tap') ||
            lower.contains('register') ||
            lower.contains('sign up') ||
            lower.contains('join now');
    if (!hasUrl && hasGambling && hasClaimOrTapAction) {
      score += 0.1;
      reasons.add('Casino or gambling bait is paired with a call to action.');
    }

    return _SignalBundle(scoreDelta: score, reasons: reasons);
  }

  String _normalizeForScoring(String message) {
    var normalized = message.replaceAll('\n', ' ');
    normalized = normalized.replaceAllMapped(
      RegExp(r'((https?:\/\/|www\.)\S+)', caseSensitive: false),
      (_) => ' [LINK] ',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'\b\d{4,8}\b'),
      (_) => ' [NUM] ',
    );
    normalized = normalized.replaceAll(RegExp(r'\s+'), ' ');
    return normalized.trim();
  }

  bool _isTrustedSender(String sender) {
    final String trimmed = sender.trim();
    if (trimmed.isEmpty) {
      return false;
    }
    final String upper = trimmed.toUpperCase();
    final String canonical = _canonicalizeSenderId(trimmed);
    return _trustedSenderIds.contains(upper) ||
        _trustedSenderIds.contains(canonical);
  }

  String _canonicalizeSenderId(String sender) {
    return sender.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  List<String> _uniqueReasons(List<String> reasons) {
    final Set<String> seen = <String>{};
    final List<String> deduped = <String>[];
    for (final String reason in reasons) {
      final String trimmed = reason.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      deduped.add(trimmed);
      if (deduped.length == 4) {
        break;
      }
    }
    if (deduped.isEmpty) {
      return const <String>['No major smishing indicators detected.'];
    }
    return deduped;
  }
}

class _SignalBundle {
  const _SignalBundle({
    required this.scoreDelta,
    required this.reasons,
  });

  final double scoreDelta;
  final List<String> reasons;
}

class _KeywordGroup {
  const _KeywordGroup({
    required this.weight,
    required this.reason,
    required this.patterns,
  });

  final double weight;
  final String reason;
  final List<String> patterns;

  bool matches(String normalized) {
    final String lower = normalized.toLowerCase();
    for (final String pattern in patterns) {
      if (lower.contains(pattern.toLowerCase())) {
        return true;
      }
    }
    return false;
  }
}
