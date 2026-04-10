// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/services/ai_detection_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AIDetectionService smoke', () {
    final service = AIDetectionService();

    setUpAll(() async {
      await service.loadModel();
    });

    test('trusted OTP whitelist stays heuristic-only', () async {
      final result = await service.scoreSmsRisk(
        'Your OTP code is 123456. Do not share this code with anyone.',
        sender: 'GCASH',
      );

      expect(result.usedModel, isFalse);
      expect(result.modelScore, isNull);
      expect(result.riskLevel, 'safe');
      expect(result.riskScore, lessThan(0.2));
    });

    test('trusted sender promo with no link stays safe', () async {
      final result = await service.scoreSmsRisk(
        "Nice! You received a P20 voucher from Maya. Use it for your load, bills, shopping and more. Tap 'Vouchers' on the app to claim your gift before it expires!",
        sender: 'MAYA',
      );

      expect(result.isSuspicious, isFalse);
      expect(result.pipelineStage, 'allowlist');
      expect(result.detectionSource, 'allowlist_sender');
    });

    test('obvious smishing message uses DistilBERT path', () async {
      if (!service.isModelLoaded) {
        print(
          'Skipping DistilBERT runtime assertion on this host because the '
          'TensorFlow Lite native library is unavailable.',
        );
        return;
      }

      final result = await service.scoreSmsRisk(
        'URGENT: Your account is suspended. Verify immediately at http://bit.ly/reset-login to avoid closure.',
        sender: '+639123456789',
      );

      expect(result.usedModel, isTrue);
      expect(result.modelScore, isNotNull);
      expect(result.reasons, isNotEmpty);
    });

    test('no-link credential scam still triggers heuristic fallback', () async {
      final result = await service.scoreSmsRisk(
        'URGENT: Your account is suspended. Reply now with your OTP and verification code to avoid permanent closure.',
        sender: '+639123456789',
      );

      expect(result.pipelineStage, 'heuristic_fallback');
      expect(result.isSuspicious, isTrue);
      expect(result.riskScore, greaterThanOrEqualTo(0.42));
    });

    test('casino bait with link reaches high risk', () async {
      final result = await service.scoreSmsRisk(
        'CasinoPlus bonus! Claim your free spins jackpot now at http://bit.ly/casinoplus-bonus before it expires tonight.',
        sender: '+639123456789',
      );

      expect(result.isSuspicious, isTrue);
      expect(result.riskLevel, 'high');
      expect(result.riskScore, greaterThanOrEqualTo(0.72));
    });

    test('smishing sample scores higher than benign conversational text', () async {
      final suspicious = await service.scoreSmsRisk(
        'Security alert! Update your bank account immediately at http://secure-login-alert.com',
        sender: '+639123456789',
      );
      final benign = await service.scoreSmsRisk(
        'Hi, pauwi na ako. Bili ka na lang ng tubig pagdaan ko.',
        sender: '+639987654321',
      );

      expect(suspicious.heuristicScore, greaterThan(benign.heuristicScore));
      expect(suspicious.riskScore, greaterThan(benign.riskScore));
    });
  });
}
