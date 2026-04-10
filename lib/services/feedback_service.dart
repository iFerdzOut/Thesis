import 'package:flutter/foundation.dart';

import '../models/feedback_log_model.dart';
import '../models/message_model.dart';
import 'feedback_database_service.dart';
import 'local_detection_repository.dart';
import 'sms_service.dart';
import 'sms_storage_service.dart';
import 'trusted_domain_service.dart';

class FeedbackService {
  FeedbackService._internal();

  static final FeedbackService instance = FeedbackService._internal();
  factory FeedbackService() => instance;

  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final TrustedDomainService _trustedDomainService = TrustedDomainService();
  final SmsStorageService _smsStorageService = SmsStorageService();
  final FeedbackDatabaseService _remoteFeedback = FeedbackDatabaseService();

  Future<void> markSmsFalsePositiveAndRestore(String quarantineId) async {
    final Map<String, dynamic>? entry =
        await _smsStorageService.getQuarantineMessage(quarantineId);
    if (entry == null) {
      return;
    }

    await _repository.initialize();
    final String primaryDomain = entry['primaryDomain']?.toString() ?? '';
    if (primaryDomain.isNotEmpty) {
      await _trustedDomainService.addTrustedDomain(
        rawDomainOrUrl: primaryDomain,
        source: 'user_false_positive',
        note: 'Added from quarantine false-positive feedback.',
      );
    }

    final FeedbackLogModel log = FeedbackLogModel(
      messageKey: entry['messageKey']?.toString() ?? quarantineId,
      label: 'false_positive',
      source: 'sms',
      sender: entry['sender']?.toString() ?? '',
      primaryDomain: primaryDomain.isEmpty ? null : primaryDomain,
      riskScore: (entry['riskScore'] as num?)?.toDouble(),
      notes: 'Marked safe from quarantine restore.',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _repository.logFeedback(log);
    await _smsStorageService.restoreQuarantineMessage(quarantineId);
    try {
      await _remoteFeedback.saveFalsePositive(
        message: entry['message']?.toString() ?? '',
        source: 'sms',
        sender: entry['sender']?.toString(),
      );
    } catch (error) {
      debugPrint('[FeedbackService] Remote false-positive export failed: $error');
    }
  }

  Future<void> reportSmsMessageAsSmishing({
    required String peer,
    required MessageModel message,
  }) async {
    await _repository.initialize();
    final bool confirmedByModel = message.isSuspicious;
    final String label =
        confirmedByModel ? 'confirmed_smishing' : 'false_negative';

    if (message.providerId != null && message.providerId! > 0) {
      await SmsService.deleteProviderMessage(message.providerId!);
      await _smsStorageService.removeVisibleProviderMessage(
        peer: peer,
        providerId: message.providerId!,
      );
    }

    await _smsStorageService.saveToQuarantine(
      SmsMessage(
        sender: peer,
        body: message.text,
        time: message.time,
        isSuspicious: true,
        simSlot: 0,
        riskScore: message.riskScore ?? 0.0,
        riskLevel: message.riskLevel ?? 'high',
        detectionReasons: message.detectionReasons.isEmpty
            ? <String>[
                confirmedByModel
                    ? 'User confirmed the message is smishing.'
                    : 'User reported the message as a missed smishing case.',
              ]
            : message.detectionReasons,
        modelScore: message.modelScore,
        heuristicScore: message.heuristicScore ?? 0.0,
        detectionSource: message.detectionSource ?? 'manual_feedback',
        pipelineStage: message.pipelineStage ?? 'manual_review',
        providerId: message.providerId,
        providerThreadId: message.providerThreadId,
        messageKey: message.messageKey,
        detectionDecision: message.detectionDecision ??
            (confirmedByModel ? 'confirmed_smishing' : 'false_negative'),
        extractedUrls: message.extractedUrls,
        primaryUrl: message.primaryUrl,
        primaryDomain: message.primaryDomain,
        needsRescan: false,
      ),
    );

    final FeedbackLogModel log = FeedbackLogModel(
      messageKey: message.messageKey ??
          'manual_${peer}_${message.time.millisecondsSinceEpoch}',
      label: label,
      source: 'sms',
      sender: peer,
      primaryDomain: message.primaryDomain,
      riskScore: message.riskScore,
      notes: confirmedByModel
          ? 'Visible suspicious SMS confirmed by user.'
          : 'Visible SMS reported as false negative by user.',
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    await _repository.logFeedback(log);

    try {
      if (confirmedByModel) {
        await _remoteFeedback.saveConfirmedSmishing(
          message: message.text,
          source: 'sms',
          sender: peer,
        );
      } else {
        await _remoteFeedback.saveFalseNegative(
          message: message.text,
          source: 'sms',
          sender: peer,
        );
      }
    } catch (error) {
      debugPrint('[FeedbackService] Remote SMS feedback export failed: $error');
    }
  }
}
