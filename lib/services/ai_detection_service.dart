import '../models/screened_message_model.dart';
import 'message_screening_service.dart';

class HybridRiskResult {
  final double riskScore;
  final double heuristicScore;
  final double? modelScore;
  final String riskLevel;
  final bool isSuspicious;
  final bool shouldQuarantine;
  final bool usedModel;
  final String detectionSource;
  final String pipelineStage;
  final List<String> reasons;

  const HybridRiskResult({
    required this.riskScore,
    required this.heuristicScore,
    required this.modelScore,
    required this.riskLevel,
    required this.isSuspicious,
    required this.shouldQuarantine,
    required this.usedModel,
    required this.detectionSource,
    required this.pipelineStage,
    required this.reasons,
  });

  String get summary =>
      reasons.isEmpty ? 'No major smishing indicators detected.' : reasons.join(' ');
}

class AIDetectionService {
  final MessageScreeningService _screeningService = MessageScreeningService();

  bool get isModelLoaded => _screeningService.isModelLoaded;

  Future<void> loadModel() {
    return _screeningService.loadModel();
  }

  Future<bool> detectSmishing(String message, {String sender = ''}) async {
    final HybridRiskResult result =
        await scoreMessageRisk(message, sender: sender);
    return result.isSuspicious;
  }

  Future<HybridRiskResult> scoreSmsRisk(String message, {String sender = ''}) {
    return scoreMessageRisk(message, sender: sender);
  }

  Future<HybridRiskResult> scoreMessageRisk(
    String message, {
    String sender = '',
  }) async {
    final int timestampMs = DateTime.now().millisecondsSinceEpoch;
    final String body = message.trim();
    final String messageKey =
        'compat_${sender.trim()}_${timestampMs}_${body.hashCode}';
    final result = await _screeningService.screenMessage(
      ScreenedMessageModel(
        source: 'compat',
        sender: sender,
        peer: sender,
        body: body,
        timestampMs: timestampMs,
        messageKey: messageKey,
        providerId: null,
        providerThreadId: null,
        simSlot: null,
        subscriptionId: null,
      ),
      forceRescore: true,
    );
    return result.toHybridRiskResult();
  }
}
