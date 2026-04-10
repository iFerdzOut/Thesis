import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/models/detection_result_model.dart';
import 'package:flutter_application_1/models/screened_message_model.dart';
import 'package:flutter_application_1/services/message_screening_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = MessageScreeningService();

  group('Strict SMS screening for wrapped help links', () {
    test('wrapped help link no longer falls into sms_no_url_allow', () async {
      final result = await service.screenMessage(
        ScreenedMessageModel(
          source: 'sms',
          sender: '+639123456789',
          peer: '+639123456789',
          body:
              '<;w1plsMega.help;> Celebrate family time this Sunday! Claim your P3,888 bonus and share achievements on Facebook for an extra P50. Win up to P16M!',
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          messageKey:
              'test_help_sms_${DateTime.now().millisecondsSinceEpoch}',
          providerId: null,
          providerThreadId: null,
          simSlot: null,
          subscriptionId: null,
        ),
        forceRescore: true,
      );

      expect(result.hasUrl, isTrue);
      expect(result.extractedUrls, isNotEmpty);
      expect(
        result.extractedUrls.first.toLowerCase(),
        contains('w1plsmega.help'),
      );
      expect(result.detectionSource, isNot('sms_no_url_allow'));
      expect(result.decision, isNot(DetectionDecision.noUrlAllow));
    });

    test('genuinely no-url safe sms still uses no_url_allow', () async {
      final result = await service.screenMessage(
        ScreenedMessageModel(
          source: 'sms',
          sender: 'MAYA',
          peer: 'MAYA',
          body:
              "Nice! You received a P20 voucher from Maya. Use it for your load, bills, shopping, and more. Tap 'Vouchers' on the app to claim your gift before it expires!",
          timestampMs: DateTime.now().millisecondsSinceEpoch,
          messageKey:
              'test_safe_sms_${DateTime.now().millisecondsSinceEpoch}',
          providerId: null,
          providerThreadId: null,
          simSlot: null,
          subscriptionId: null,
        ),
        forceRescore: true,
      );

      expect(result.hasUrl, isFalse);
      expect(result.decision, DetectionDecision.noUrlAllow);
      expect(result.detectionSource, 'sms_no_url_allow');
    });
  });
}
