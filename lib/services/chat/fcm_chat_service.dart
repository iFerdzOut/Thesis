// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

import '../../models/safety_status.dart';
import '../../smishing_detection_pipeline/pipeline_service.dart';
import 'chat_notification_service.dart';

class FcmChatService {
  static final FcmChatService _instance = FcmChatService._internal();
  factory FcmChatService() => _instance;
  FcmChatService._internal();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final SmishingPipelineService _pipelineService = SmishingPipelineService();
  bool _foregroundListenerRegistered = false;

  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  static const String _chatPushEndpoint =
      'https://smishing-call-push-backend.vercel.app/api/send-chat-push';

  void initForegroundNotifications() {
    if (_foregroundListenerRegistered) return;
    _foregroundListenerRegistered = true;

    FirebaseMessaging.onMessage.listen((message) async {
      final data = message.data;
      final type = data['type']?.trim();
      if (type != 'chat') return;

      final chatId = data['chatId']?.trim() ?? '';
      final messageId = data['messageId']?.trim() ?? '';
      final senderId = data['senderId']?.trim() ?? '';
      final senderName = data['senderName']?.trim().isNotEmpty == true
          ? data['senderName']!.trim()
          : 'New message';
      final screeningPreview = await screenReceivedChatPush(data);
      final preview = screeningPreview ??
          await _resolveForegroundPreview(
            chatId: chatId,
            messageId: messageId,
            fallbackPreview: data['preview']?.trim() ?? 'New message',
            messageType: data['messageType']?.trim() ?? 'text',
          );

      if (chatId.isEmpty || messageId.isEmpty || senderId.isEmpty) return;

      await ChatNotificationService().showForegroundChatNotification(
        chatId: chatId,
        messageId: messageId,
        senderId: senderId,
        senderName: senderName,
        preview: preview,
      );
    });
  }

  Future<String> _resolveForegroundPreview({
    required String chatId,
    required String messageId,
    required String fallbackPreview,
    required String messageType,
  }) async {
    if (messageType != 'text') {
      return fallbackPreview;
    }

    try {
      final doc = await _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .get();
      final data = doc.data();
      if (data == null) return fallbackPreview;
      final text = data['text']?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
      return fallbackPreview;
    } catch (_) {
      return fallbackPreview;
    }
  }

  Future<String?> screenReceivedChatPush(
    Map<String, dynamic> data, {
    bool runModel = false,
  }) async {
    final type = data['type']?.trim();
    if (type != 'chat') return null;

    final chatId = data['chatId']?.trim() ?? '';
    final messageId = data['messageId']?.trim() ?? '';
    final senderId = data['senderId']?.trim() ?? '';
    final receiverId = data['receiverId']?.trim() ?? '';
    final receiverUserId =
        currentUserId.isNotEmpty ? currentUserId : receiverId;
    if (chatId.isEmpty ||
        messageId.isEmpty ||
        senderId.isEmpty ||
        receiverUserId.isEmpty ||
        senderId == receiverUserId) {
      return null;
    }

    try {
      final messageRef = _db
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId);
      final doc = await messageRef.get();
      final messageData = doc.data();
      if (messageData == null) return null;

      final messageType = (messageData['type'] ??
              messageData['messageType'] ??
              data['messageType'] ??
              'text')
          .toString()
          .trim()
          .toLowerCase();
      if (messageType != 'text' ||
          messageData['isDeleted'] == true ||
          messageData['type'] == 'deleted') {
        return null;
      }

      if ((messageData['screenedForReceiverId']?.toString().trim() ?? '') ==
          receiverUserId) {
        final existingStatus =
            SafetyStatus.fromValue(messageData['safetyStatus']?.toString());
        if (existingStatus == SafetyStatus.malicious ||
            messageData['isSuspicious'] == true) {
          return 'Suspicious message blocked';
        }
        return messageData['text']?.toString().trim();
      }

      final text = messageData['text']?.toString().trim() ?? '';
      if (text.isEmpty) {
        await messageRef.set({
          'screenedForReceiverId': receiverUserId,
          'screenedForReceiverAt': FieldValue.serverTimestamp(),
          'safetyStatus': SafetyStatus.safe.value,
        }, SetOptions(merge: true));
        return null;
      }

      if (!runModel) {
        await messageRef.set({
          'safetyStatus': SafetyStatus.scanning.value,
          'screeningStartedAtClientMs': DateTime.now().millisecondsSinceEpoch,
        }, SetOptions(merge: true));
        return 'Message received - scanning for safety';
      }

      await messageRef.set({
        'safetyStatus': SafetyStatus.scanning.value,
        'screeningStartedAtClientMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));

      final timestampMs = _timestampMsFromMessage(messageData);
      final messageKey =
          messageData['clientMessageId']?.toString().trim().isNotEmpty == true
              ? messageData['clientMessageId'].toString().trim()
              : messageId;
      final result = await _pipelineService.deepScan(
        ScreenedMessageModel(
          source: 'online_chat',
          sender: senderId,
          peer: receiverUserId,
          body: text,
          timestampMs: timestampMs,
          messageKey: messageKey,
          providerId: null,
          providerThreadId: null,
          simSlot: null,
          subscriptionId: null,
        ),
      );

      final quarantined = result.shouldQuarantine;
      await messageRef.set({
        'isSuspicious': quarantined,
        'safetyStatus': quarantined
            ? SafetyStatus.malicious.value
            : SafetyStatus.safe.value,
        'riskScore': result.riskScore,
        'riskLevel': result.riskLevel,
        'detectionReasons': result.explanations,
        'modelScore': result.modelScore,
        'heuristicScore': result.heuristicScore,
        'detectionSource': result.detectionSource,
        'pipelineStage': result.pipelineStage,
        'detectionDecision': result.decision,
        'extractedUrls': result.extractedUrls,
        'primaryUrl': result.primaryUrl,
        'primaryDomain': result.primaryDomain,
        'needsRescan': result.needsRescan,
        'screenedForReceiverId': receiverUserId,
        'screenedForReceiverAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (quarantined) {
        await _saveReceivedChatQuarantine(
          receiverUserId: receiverUserId,
          sender: data['senderName']?.trim().isNotEmpty == true
              ? data['senderName']!.trim()
              : senderId,
          message: text,
          messagePath: messageRef.path,
          messageId: messageId,
          result: result,
        );
        return 'Suspicious message blocked';
      }

      return text;
    } catch (e) {
      print('[FcmChatService] chat push screening failed: $e');
      return null;
    }
  }

  int _timestampMsFromMessage(Map<String, dynamic> data) {
    final raw = data['timestamp'] ?? data['editedAt'] ?? data['updatedAt'];
    if (raw is Timestamp) return raw.toDate().millisecondsSinceEpoch;
    if (raw is DateTime) return raw.millisecondsSinceEpoch;
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) {
      final parsedInt = int.tryParse(raw);
      if (parsedInt != null) return parsedInt;
      final parsedDate = DateTime.tryParse(raw);
      if (parsedDate != null) return parsedDate.millisecondsSinceEpoch;
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> _saveReceivedChatQuarantine({
    required String receiverUserId,
    required String sender,
    required String message,
    required String messagePath,
    required String messageId,
    required DetectionResultModel result,
  }) async {
    final quarantineId = 'online_${messagePath.replaceAll('/', '_')}';
    await _db
        .collection('users')
        .doc(receiverUserId)
        .collection('quarantine')
        .doc(quarantineId)
        .set({
      'sender': sender,
      'message': message,
      'source': 'online',
      'messageDocPath': messagePath,
      'restoreMode': 'messageDoc',
      'messageId': messageId,
      'messageKey': result.messageKey,
      'detectionDecision': result.decision,
      'extractedUrls': result.extractedUrls,
      'primaryUrl': result.primaryUrl,
      'primaryDomain': result.primaryDomain,
      'needsRescan': result.needsRescan,
      'safetyStatus': SafetyStatus.malicious.value,
      'isSuspicious': true,
      'riskScore': result.riskScore,
      'riskLevel': result.riskLevel,
      'detectionReasons': result.explanations,
      'modelScore': result.modelScore,
      'heuristicScore': result.heuristicScore,
      'detectionSource': result.detectionSource,
      'pipelineStage': result.pipelineStage,
      'reportedAtClientMs': DateTime.now().millisecondsSinceEpoch,
      'reportedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> notifyIncomingChat({
    required String receiverId,
    required String chatId,
    required String messageId,
    required String senderName,
    required String preview,
    required String type,
  }) async {
    try {
      final receiverDoc = await _db.collection('users').doc(receiverId).get();
      final fcmToken = receiverDoc.data()?['fcmToken'] as String?;
      final receiverSettings = await _db
          .collection('users')
          .doc(receiverId)
          .collection('chat_settings')
          .doc(currentUserId)
          .get();
      final receiverSettingsData =
          receiverSettings.data() ?? const <String, dynamic>{};

      if (receiverSettingsData['blocked'] == true) {
        print(
          '[FcmChatService] Push suppressed because receiver blocked sender=$currentUserId',
        );
        return;
      }

      if (receiverSettingsData['mutedNotifications'] == true) {
        print(
          '[FcmChatService] Push suppressed because receiver muted sender=$currentUserId',
        );
        return;
      }

      if (fcmToken == null || fcmToken.isEmpty) {
        print('[FcmChatService] No FCM token for receiver=$receiverId');
        return;
      }

      final payload = {
        'token': fcmToken,
        'type': 'chat',
        'chatId': chatId,
        'messageId': messageId,
        'senderId': currentUserId,
        'senderName': senderName,
        'receiverId': receiverId,
        'preview': preview,
        'messageType': type,
      };

      final response = await http.post(
        Uri.parse(_chatPushEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      print(
        '[FcmChatService] Push response: ${response.statusCode} ${response.body}',
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        print('[FcmChatService] Chat push request sent successfully');
      } else if (response.statusCode == 500 &&
          response.body.contains('Requested entity was not found')) {
        print(
          '[FcmChatService] Stale token detected for receiver=$receiverId; '
          'skipping client-side token cleanup',
        );
      } else {
        print('[FcmChatService] Chat push request failed');
      }
    } catch (e) {
      print('[FcmChatService] notifyIncomingChat error: $e');
    }
  }
}
