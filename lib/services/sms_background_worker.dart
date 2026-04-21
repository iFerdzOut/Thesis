import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:workmanager/workmanager.dart';
import 'package:permission_handler/permission_handler.dart';

import '../smishing_detector.dart';

/// Rule 3: SMS Channel - Silent background batching (10 at a time).
/// No mass upfront scanning.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    print('==================================================');
    print('[SMS Worker] WAKING UP! Executing task: $task');
    try {
      // Initialize platform channels for background execution
      final token = RootIsolateToken.instance;
      if (token != null) {
        BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      }

      if (!await Permission.sms.isGranted) {
        print('[SMS Worker] SMS permission not granted. Going back to sleep.');
        print('==================================================');
        return Future.value(true);
      }

      final SmsQuery query = SmsQuery();
      // Fetch only the 10 most recent messages
      final List<SmsMessage> messages = await query.querySms(
        kinds: [SmsQueryKind.inbox],
        count: 10,
      );
      
      print('[SMS Worker] Fetched ${messages.length} messages from inbox.');

      final SmishingDetector detector = SmishingDetector();

      for (final msg in messages) {
        final body = msg.body;
        if (body == null || body.isEmpty) continue;
        
        print('[SMS Worker] Scanning message: "${body.length > 30 ? '${body.substring(0, 30)}...' : body}"');

        // Execute the ML Pipeline (Layer 1 Heuristics -> Layer 2 DistilBERT)
        final isSmishing = await detector.analyzeMessage(body);
        
        if (isSmishing) {
          // TODO: Move the message to the local SQLite Quarantine Vault
          print('🚨 [SMS Worker] SMISHING DETECTED: ${msg.id}');
        } else {
          print('✅ [SMS Worker] Safe.');
        }
      }
      print('[SMS Worker] Batch scan complete. Going back to sleep.');
      print('==================================================');
      return Future.value(true);
    } catch (e) {
      print('[SMS Worker] Task failed with error: $e');
      return Future.value(false);
    }
  });
}

class SmsBackgroundWorker {
  static void initialize() {
    Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: kDebugMode,
    );
  }

  static void registerPeriodicScan() {
    Workmanager().registerPeriodicTask(
      "sms_batch_scan_10",
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