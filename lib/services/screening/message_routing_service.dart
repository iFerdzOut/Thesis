import '../../smishing_detection_pipeline/pipeline_service.dart';

class MessageRoutingService {
  const MessageRoutingService();

  bool shouldQuarantine(DetectionResultModel result) {
    return result.decision == DetectionDecision.quarantineHighRisk;
  }

  bool shouldAllowInbox(DetectionResultModel result) {
    return !shouldQuarantine(result);
  }

  bool shouldRequestRescan(DetectionResultModel result) {
    return result.decision == DetectionDecision.modelErrorFallback &&
        result.needsRescan;
  }
}
