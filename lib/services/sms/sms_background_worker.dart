import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:workmanager/workmanager.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/safety_status.dart';
import '../../smishing_detection_pipeline/pipeline_service.dart';
import 'sms_storage_service.dart' as storage;

/// Rule 3: SMS Channel - Silent background batching.
/// No mass upfront scanning.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    debugPrint('==================================================');
    debugPrint('[SMS Worker] WAKING UP! Executing task: $task');
    try {
      // Initialize platform channels for background execution
      final token = RootIsolateToken.instance;
      if (token != null) {
        BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      }

      if (!await Permission.sms.isGranted) {
        debugPrint('[SMS Worker] SMS permission not granted. Going back to sleep.');
        debugPrint('==================================================');
        return Future.value(true);
      }

      final SmsQuery query = SmsQuery();
      // Fetch only a small recent batch for the legacy worker path.
      final List<SmsMessage> messages = await query.querySms(
        kinds: [SmsQueryKind.inbox],
        count: 5,
      );

      debugPrint('[SMS Worker] Fetched ${messages.length} messages from inbox.');

      final SmishingPipelineService pipelineService =
          SmishingPipelineService();
      await pipelineService.initialize();

      for (final msg in messages) {
        final body = msg.body;
        if (body == null || body.isEmpty) continue;

        debugPrint('[SMS Worker] Scanning message: "${body.length > 30 ? '${body.substring(0, 30)}...' : body}"');

        final screenedMsg = ScreenedMessageModel(
          source: 'sms',
          sender: msg.address ?? 'Unknown',
          peer: msg.address ?? 'Unknown',
          body: body,
          timestampMs: msg.dateSent?.millisecondsSinceEpoch ??
              DateTime.now().millisecondsSinceEpoch,
          messageKey: 'worker_${msg.id}_${body.hashCode}',
          providerId: msg.id,
          providerThreadId: msg.threadId?.toString(),
          simSlot: null,
          subscriptionId: null,
        );

        final result = await pipelineService.deepScan(screenedMsg);

        if (result.shouldQuarantine) {
          final storageMsg = storage.SmsMessage(
            sender: msg.address ?? 'Unknown',
            body: body,
            time: msg.dateSent ?? DateTime.now(),
            source: 'sms',
            isSuspicious: true,
            providerId: msg.id,
            providerThreadId: msg.threadId?.toString(),
            messageKey: screenedMsg.messageKey,
            riskScore: result.riskScore,
            riskLevel: result.riskLevel,
            detectionReasons: result.explanations,
            modelScore: result.modelScore,
            heuristicScore: result.heuristicScore,
            detectionSource: result.detectionSource,
            pipelineStage: result.pipelineStage,
            detectionDecision: result.decision,
            extractedUrls: result.extractedUrls,
            primaryUrl: result.primaryUrl,
            primaryDomain: result.primaryDomain,
            needsRescan: result.needsRescan,
            safetyStatus: SafetyStatus.malicious,
          );
          await storage.SmsStorageService().saveToQuarantine(storageMsg);
          debugPrint('🚨 [SMS Worker] SMISHING DETECTED & QUARANTINED: ${msg.id}');
        } else {
          debugPrint('✅ [SMS Worker] Safe.');
        }
      }
      debugPrint('[SMS Worker] Batch scan complete. Going back to sleep.');
      debugPrint('==================================================');
      return Future.value(true);
    } catch (e) {
      debugPrint('[SMS Worker] Task failed with error: $e');
      return Future.value(false);
    }
  });
}

class SmsBackgroundWorker {
  static void initialize() {
    Workmanager().initialize(callbackDispatcher);
  }

  static void registerPeriodicScan() {
    Workmanager().registerPeriodicTask(
      "sms_batch_scan_recent",
      "smsBatchScanTask",
      frequency: const Duration(minutes: 15), // Android minimum frequency
      constraints: Constraints(
        networkType: NetworkType.notRequired, // Offline ML inference
        requiresBatteryNotLow: true,
      ),
    );
  }

  /// Temporary method to force an immediate background scan for testing
  static void triggerImmediateScanTest() {
    Workmanager().registerOneOffTask(
      "immediate_scan_test",
      "smsBatchScanTask",
      existingWorkPolicy: ExistingWorkPolicy.replace,
    );
  }
}
