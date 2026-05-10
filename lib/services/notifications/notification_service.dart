// ignore_for_file: avoid_print

import 'package:flutter/services.dart';

/// NotificationService
///
/// Shows notifications for safe SMS messages.
/// SUPPRESSES notifications for suspicious/quarantined messages
/// so scam content never leaks into the Android notification shade.
///
/// Uses a MethodChannel to call native Android notification code.
class NotificationService {
  static const MethodChannel _channel = MethodChannel('sms_channel');

  /// Show a normal notification for a safe SMS
  static Future<void> showSafeNotification({
    required String sender,
    required String body,
    int? timestampMs,
  }) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'sender': sender,
        'body': body,
        'isSuspicious': false,
        if (timestampMs != null) 'timestamp': timestampMs,
      });
      print('[NotificationService] Showed safe notification from $sender');
    } catch (e) {
      print('[NotificationService] Error showing notification: $e');
    }
  }

  /// Show a warning notification for a suspicious SMS
  /// NOTE: This only shows "New suspicious message blocked"
  /// NOT the actual message content — so scam text never leaks
  static Future<void> showSuspiciousNotification({
    required String sender,
  }) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'sender': sender,
        'body':
            'A suspicious message was blocked and sent to Quarantine Vault.',
        'isSuspicious': true,
      });
      print('[NotificationService] Showed suspicious warning for $sender');
    } catch (e) {
      print('[NotificationService] Error showing suspicious notification: $e');
    }
  }

  /// Show a normal notification for an in-app chat message preview.
  static Future<void> showChatNotification({
    required String chatId,
    required String messageId,
    required String senderId,
    required String sender,
    required String body,
  }) async {
    try {
      await _channel.invokeMethod('showChatNotification', {
        'chatId': chatId,
        'messageId': messageId,
        'senderId': senderId,
        'sender': sender,
        'body': body,
      });
      print('[NotificationService] Showed chat notification from $sender');
    } catch (e) {
      print('[NotificationService] Error showing chat notification: $e');
    }
  }

  static Future<void> showFriendRequestNotification({
    required String senderId,
    required String sender,
  }) async {
    try {
      await _channel.invokeMethod('showFriendRequestNotification', {
        'senderId': senderId,
        'sender': sender,
      });
    } catch (e) {
      print(
        '[NotificationService] Error showing friend request notification: $e',
      );
    }
  }
}
