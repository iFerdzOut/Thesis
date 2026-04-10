import 'dart:math' as math;

import 'local_detection_repository.dart';
import '../models/detection_result_model.dart';

class RiskScoringService {
  RiskScoringService._internal();

  static final RiskScoringService instance = RiskScoringService._internal();
  factory RiskScoringService() => instance;

  final LocalDetectionRepository _repository = LocalDetectionRepository();

  Future<double> get warningThreshold async {
    return _repository.getWarningThreshold();
  }

  Future<double> get quarantineThreshold async {
    return _repository.getQuarantineThreshold();
  }

  Future<List<double>> softmax(List<double> logits) async {
    if (logits.isEmpty) {
      return const <double>[];
    }
    final double maxLogit = logits.reduce((double a, double b) => a > b ? a : b);
    final List<double> exps = logits
        .map((double value) => math.exp(value - maxLogit))
        .toList(growable: false);
    final double sum = exps.fold<double>(0.0, (double acc, double item) => acc + item);
    if (sum == 0) {
      return List<double>.filled(logits.length, 0.0, growable: false);
    }
    return exps.map((double value) => value / sum).toList(growable: false);
  }

  Future<double> scoreFromLogits(
    List<double> logits, {
    int positiveIndex = 1,
  }) async {
    final List<double> probabilities = await softmax(logits);
    if (probabilities.isEmpty) {
      return 0.0;
    }
    final int safeIndex =
        positiveIndex >= 0 && positiveIndex < probabilities.length
            ? positiveIndex
            : probabilities.length - 1;
    return probabilities[safeIndex].clamp(0.0, 1.0);
  }

  Future<String> levelFromScore(double score) async {
    final double warning = await warningThreshold;
    final double quarantine = await quarantineThreshold;
    if (score >= quarantine) {
      return 'high';
    }
    if (score >= warning) {
      return 'medium';
    }
    return 'safe';
  }

  Future<String> decisionFor({
    required bool hasUrl,
    required bool trustedMatch,
    required bool modelError,
    required double riskScore,
  }) async {
    final double quarantine = await quarantineThreshold;
    if (trustedMatch) {
      return DetectionDecision.allowTrusted;
    }
    if (modelError) {
      return DetectionDecision.modelErrorFallback;
    }
    if (riskScore >= quarantine) {
      return DetectionDecision.quarantineHighRisk;
    }
    if (!hasUrl) {
      return DetectionDecision.noUrlAllow;
    }
    return DetectionDecision.allowLowRisk;
  }
}
