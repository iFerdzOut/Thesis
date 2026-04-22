// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

import 'chat_notification_service.dart';
import 'security_service.dart';

class FcmChatService {
  static final FcmChatService _instance = FcmChatService._internal();
  factory FcmChatService() => _instance;
  FcmChatService._internal();

  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final SecurityService _securityService = SecurityService();
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
      final preview = await _resolveForegroundPreview(
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
    if (messageType != 'text' ||
        (fallbackPreview.isNotEmpty &&
            !fallbackPreview.toLowerCase().contains('encrypted message'))) {
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
      if (data['e2ee'] == true) {
        try {
          final decrypted = await _securityService.decryptMessage(data);
          return decrypted;
        } catch (_) {
          return 'RSA encrypted message';
        }
      }
      final text = data['text']?.toString().trim() ?? '';
      return text.isNotEmpty ? text : fallbackPreview;
    } catch (_) {
      return fallbackPreview;
    }
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
        print('[FcmChatService] Stale token detected, clearing saved token');
        await _db.collection('users').doc(receiverId).update({
          'fcmToken': FieldValue.delete(),
        });
      } else {
        print('[FcmChatService] Chat push request failed');
      }
    } catch (e) {
      print('[FcmChatService] notifyIncomingChat error: $e');
    }
  }
}
