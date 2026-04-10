import '../services/ai_detection_service.dart';

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
  final double warningThreshold;
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
    required this.warningThreshold,
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

  bool get isSuspicious => riskScore >= warningThreshold;
  bool get shouldQuarantine =>
      decision == DetectionDecision.quarantineHighRisk ||
      (decision != DetectionDecision.modelErrorFallback &&
          riskScore >= quarantineThreshold);

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
      'warningThreshold': warningThreshold,
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

  HybridRiskResult toHybridRiskResult() {
    return HybridRiskResult(
      riskScore: riskScore,
      heuristicScore: heuristicScore,
      modelScore: modelScore,
      riskLevel: riskLevel,
      isSuspicious: isSuspicious,
      shouldQuarantine: shouldQuarantine,
      usedModel: mlInvoked,
      detectionSource: detectionSource,
      pipelineStage: pipelineStage,
      reasons: explanations,
    );
  }

  factory DetectionResultModel.fromMap(Map<String, dynamic> map) {
    final decision = map['decision']?.toString() ?? DetectionDecision.noUrlAllow;
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
      rawLogits:
          (map['rawLogits'] as List<dynamic>? ?? const <dynamic>[])
              .map((dynamic item) => (item as num).toDouble())
              .toList(growable: false),
      riskScore: ((map['riskScore'] as num?) ?? 0).toDouble(),
      warningThreshold: ((map['warningThreshold'] as num?) ?? 0.42).toDouble(),
      quarantineThreshold:
          ((map['quarantineThreshold'] as num?) ?? 0.72).toDouble(),
      decision: DetectionDecision.values.contains(decision)
          ? decision
          : DetectionDecision.noUrlAllow,
      reason: map['reason']?.toString() ?? '',
      explanations:
          (map['explanations'] as List<dynamic>? ?? const <dynamic>[])
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
    double? warningThreshold,
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
      warningThreshold: warningThreshold ?? this.warningThreshold,
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
