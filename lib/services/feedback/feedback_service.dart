import 'package:flutter/foundation.dart';

import '../../models/feedback_log_model.dart';
import '../../models/ui_message_model.dart';
import 'feedback_database_service.dart';
import '../screening/local_detection_repository.dart';
import '../chat/online_chat_service.dart';
import '../sms/sms_service.dart';
import '../sms/sms_storage_service.dart';
import '../../smishing_detection_pipeline/pipeline_service.dart';

class FeedbackService {
  FeedbackService._internal();

  static final FeedbackService instance = FeedbackService._internal();
  factory FeedbackService() => instance;

  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final DomainAllowlist _trustedDomainService = DomainAllowlist();
  final SmsStorageService _smsStorageService = SmsStorageService();
  final FeedbackDatabaseService _remoteFeedback = FeedbackDatabaseService();
  final OnlineChatService _onlineChatService = OnlineChatService();

  Future<FeedbackUploadStatus> markSmsFalsePositiveAndRestore(
    String quarantineId,
  ) async {
    final Map<String, dynamic>? entry =
        await _smsStorageService.getQuarantineMessage(quarantineId);
    if (entry == null) {
      return FeedbackUploadStatus.disabled;
    }

    final source = entry['source']?.toString() ?? 'sms';
    final isModelFlagged = source == 'sms';

    await _repository.initialize();
    final String primaryDomain = entry['primaryDomain']?.toString() ?? '';
    if (isModelFlagged && primaryDomain.isNotEmpty) {
      await _trustedDomainService.addTrustedDomain(
        rawDomainOrUrl: primaryDomain,
        source: 'user_false_positive',
        note: 'Added from quarantine false-positive feedback.',
      );
    }

    if (isModelFlagged) {
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
    }
    FeedbackUploadStatus uploadStatus = FeedbackUploadStatus.disabled;
    await _smsStorageService.restoreQuarantineMessage(quarantineId);
    await _onlineChatService.removeSmsQuarantineMirror(quarantineId);
    try {
      if (isModelFlagged) {
        uploadStatus = await _remoteFeedback.saveFalsePositive(
          message: entry['message']?.toString() ?? '',
          source: 'sms',
          sender: entry['sender']?.toString(),
        );
      }
    } catch (error) {
      debugPrint(
          '[FeedbackService] Remote false-positive export failed: $error');
    }
    return uploadStatus;
  }

  Future<FeedbackUploadStatus> reportSmsMessageAsSmishing({
    required String peer,
    required MessageModel message,
  }) async {
    await _repository.initialize();
    final bool confirmedByModel = message.isSuspicious;
    final String label =
        confirmedByModel ? 'confirmed_smishing' : 'false_negative';
    final SmsMessage quarantinedMessage = SmsMessage(
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
      source: confirmedByModel ? 'sms' : 'false_negative_sms',
    );

    if (message.providerId != null && message.providerId! > 0) {
      await SmsService.deleteProviderMessage(message.providerId!);
      await _smsStorageService.removeVisibleProviderMessage(
        peer: peer,
        providerId: message.providerId!,
      );
    }

    await _smsStorageService.saveToQuarantine(quarantinedMessage);
    final quarantineId =
        _smsStorageService.buildQuarantineId(quarantinedMessage);
    final entry = await _smsStorageService.getQuarantineMessage(quarantineId);
    if (entry != null) {
      await _onlineChatService.upsertSmsQuarantineMirror(entry);
    }

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

    FeedbackUploadStatus uploadStatus = FeedbackUploadStatus.disabled;
    try {
      if (confirmedByModel) {
        uploadStatus = await _remoteFeedback.saveConfirmedSmishing(
          message: message.text,
          source: 'sms',
          sender: peer,
        );
      } else {
        uploadStatus = await _remoteFeedback.saveFalseNegative(
          message: message.text,
          source: 'sms',
          sender: peer,
        );
      }
    } catch (error) {
      debugPrint('[FeedbackService] Remote SMS feedback export failed: $error');
    }
    return uploadStatus;
  }
}
