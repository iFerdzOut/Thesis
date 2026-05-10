// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:collection';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../notifications/notification_service.dart';
import 'online_chat_service.dart';

class ChatNotificationService {
  ChatNotificationService._internal();

  static const MethodChannel _nativeChannel =
      MethodChannel('chat_notification_channel');

  static final ChatNotificationService _instance =
      ChatNotificationService._internal();

  factory ChatNotificationService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final OnlineChatService _onlineChatService = OnlineChatService();

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _messageSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _settingsSubscription;
  static const int _maxSeenMessageIds = 1000;
  final LinkedHashSet<String> _seenMessageIds = LinkedHashSet<String>();
  final Set<String> _mutedSenderIds = <String>{};
  final Set<String> _blockedSenderIds = <String>{};
  final Map<String, String> _senderNameCache = <String, String>{};
  final Map<String, String> _previewCache = <String, String>{};
  bool _nativeHandlerRegistered = false;

  bool _initializedSnapshot = false;
  String? _activeChatId;

  String get _currentUserId => _auth.currentUser?.uid ?? '';

  void Function({
    required String chatId,
    required String senderId,
    required String senderName,
  })? onChatNotificationTap;

  void setActiveChat(String? chatId) {
    _activeChatId = chatId;
  }

  bool shouldSuppressChatNotification(String chatId) {
    return _activeChatId == chatId;
  }

  void registerHandledMessage(String messageId) {
    if (messageId.isNotEmpty) {
      _rememberSeenMessage(messageId);
    }
  }

  void _rememberSeenMessage(String messageId) {
    final trimmedId = messageId.trim();
    if (trimmedId.isEmpty) return;
    _seenMessageIds.remove(trimmedId);
    _seenMessageIds.add(trimmedId);
    while (_seenMessageIds.length > _maxSeenMessageIds) {
      _seenMessageIds.remove(_seenMessageIds.first);
    }
  }

  void _log(String message) {
    if (kDebugMode) {
      debugPrint(message);
    }
  }

  Future<void> showForegroundChatNotification({
    required String chatId,
    required String messageId,
    required String senderId,
    required String senderName,
    required String preview,
  }) async {
    registerHandledMessage(messageId);

    if (shouldSuppressChatNotification(chatId) ||
        _isSenderSuppressed(senderId) ||
        preview.trim().isEmpty) {
      return;
    }

    await NotificationService.showChatNotification(
      chatId: chatId,
      messageId: messageId,
      senderId: senderId,
      sender: senderName,
      body: preview,
    );
  }

  void setupNativeChatHandler() {
    if (_nativeHandlerRegistered) return;
    _nativeHandlerRegistered = true;

    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method != 'onChatIntentReceived') return;
      final args = Map<String, dynamic>.from(call.arguments ?? {});
      await _handleNativeIntent(args);
    });

    unawaited(_consumePendingNativeIntent());
  }

  Future<void> _consumePendingNativeIntent() async {
    try {
      final pendingArgs = await _nativeChannel.invokeMethod<dynamic>(
        'consumePendingChatIntent',
      );
      if (pendingArgs == null) return;
      await _handleNativeIntent(
        Map<String, dynamic>.from(pendingArgs as Map<dynamic, dynamic>),
      );
    } catch (e) {
      _log('[ChatNotif] Failed to consume pending native chat intent: $e');
    }
  }

  Future<void> _handleNativeIntent(Map<String, dynamic> args) async {
    final chatId = args['chatId'] as String? ?? '';
    final messageId = args['messageId'] as String? ?? '';
    final senderId = args['senderId'] as String? ?? '';
    final senderName = args['senderName'] as String? ?? 'New message';

    if (chatId.isEmpty || senderId.isEmpty || messageId.isEmpty) {
      return;
    }

    onChatNotificationTap?.call(
      chatId: chatId,
      senderId: senderId,
      senderName: senderName,
    );

    try {
      await _nativeChannel.invokeMethod('markChatIntentHandled', {
        'chatId': chatId,
        'messageId': messageId,
      });
    } catch (e) {
      _log('[ChatNotif] Failed to acknowledge native chat intent: $e');
    }
  }

  void start() {
    final userId = _currentUserId;
    if (userId.isEmpty || _messageSubscription != null) return;

    _startSettingsListener(userId);
    _initializedSnapshot = false;
    _messageSubscription = _firestore
        .collectionGroup('messages')
        .where('receiverId', isEqualTo: userId)
        .snapshots()
        .listen(_handleMessageSnapshot, onError: (Object error) {
      _log('[ChatNotif] Listener error: $error');
    });
  }

  void _startSettingsListener(String userId) {
    _settingsSubscription?.cancel();
    _settingsSubscription = _firestore
        .collection('users')
        .doc(userId)
        .collection('chat_settings')
        .snapshots()
        .listen((snapshot) {
      _mutedSenderIds
        ..clear()
        ..addAll(snapshot.docs
            .where((doc) => doc.data()['mutedNotifications'] == true)
            .map((doc) => doc.id));
      _blockedSenderIds
        ..clear()
        ..addAll(snapshot.docs
            .where((doc) => doc.data()['blocked'] == true)
            .map((doc) => doc.id));
      unawaited(_syncNativeNotificationPreferences());
    }, onError: (Object error) {
      _log('[ChatNotif] Settings listener error: $error');
    });
  }

  bool _isSenderSuppressed(String senderId) {
    if (senderId.isEmpty) return false;
    return _mutedSenderIds.contains(senderId) ||
        _blockedSenderIds.contains(senderId);
  }

  Future<void> _syncNativeNotificationPreferences() async {
    try {
      await _nativeChannel.invokeMethod('updateChatNotificationPreferences', {
        'mutedSenderIds': _mutedSenderIds.toList(growable: false),
        'blockedSenderIds': _blockedSenderIds.toList(growable: false),
      });
    } catch (e) {
      _log('[ChatNotif] Failed to sync notification preferences: $e');
    }
  }

  Future<void> _handleMessageSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) async {
    if (!_initializedSnapshot) {
      for (final doc in snapshot.docs) {
        _rememberSeenMessage(doc.id);
      }
      _initializedSnapshot = true;
      return;
    }

    for (final change in snapshot.docChanges) {
      if (change.type != DocumentChangeType.added) continue;

      final doc = change.doc;
      final initialData = doc.data();
      if (initialData == null) continue;

      if (_seenMessageIds.contains(doc.id)) continue;
      _rememberSeenMessage(doc.id);

      final senderId = (initialData['senderId'] as String?) ?? '';
      if (senderId.isEmpty || senderId == _currentUserId) continue;

      final chatRef = doc.reference.parent.parent;
      final chatId = chatRef?.id;
      if (chatId == null) continue;

      final data = await _onlineChatService.ensureIncomingMessageScreenedAndLoad(
        messageRef: doc.reference,
        data: initialData,
      );

      unawaited(
        _onlineChatService.reconcileConversationSummaryFromLatestMessage(
          otherUserId: senderId,
          chatId: chatId,
        ),
      );

      final isRead = data['isRead'] == true;
      final isDeleted = data['isDeleted'] == true;
      final isReported = data['isReported'] == true;
      final type = (data['type'] as String?) ?? 'text';

      if (_isSenderSuppressed(senderId)) continue;
      if (isRead || isDeleted || isReported || type == 'deleted') continue;

      if (chatId == _activeChatId) continue;

      final senderName = await _resolveSenderName(
        senderId: senderId,
        messageData: data,
        chatRef: chatRef,
      );
      final preview = await _buildPreview(doc.id, data);
      if (preview.isEmpty) continue;

      await NotificationService.showChatNotification(
        chatId: chatId,
        messageId: doc.id,
        senderId: senderId,
        sender: senderName,
        body: preview,
      );
    }
  }

  Future<String> _resolveSenderName({
    required String senderId,
    required Map<String, dynamic> messageData,
    required DocumentReference<Map<String, dynamic>>? chatRef,
  }) async {
    final directName = (messageData['senderName'] as String?)?.trim();
    if (directName != null && directName.isNotEmpty) {
      return directName;
    }

    final cached = _senderNameCache[senderId];
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    if (chatRef != null) {
      try {
        final chatDoc = await chatRef.get();
        final participantNamesRaw = chatDoc.data()?['participantNames'];
        if (participantNamesRaw is Map) {
          final resolved = participantNamesRaw[senderId]?.toString().trim();
          if (resolved != null && resolved.isNotEmpty) {
            _senderNameCache[senderId] = resolved;
            return resolved;
          }
        }
      } catch (_) {}
    }

    try {
      final userDoc = await _firestore.collection('users').doc(senderId).get();
      final userData = userDoc.data() ?? <String, dynamic>{};
      final resolved = (userData['name'] as String?)?.trim().isNotEmpty == true
          ? (userData['name'] as String).trim()
          : (userData['displayName'] as String?)?.trim().isNotEmpty == true
              ? (userData['displayName'] as String).trim()
              : (userData['email'] as String?)?.trim().isNotEmpty == true
                  ? (userData['email'] as String).trim()
                  : 'New message';
      _senderNameCache[senderId] = resolved;
      return resolved;
    } catch (_) {
      return 'New message';
    }
  }

  Future<String> _buildPreview(
    String messageId,
    Map<String, dynamic> data,
  ) async {
    final type = (data['type'] as String?) ?? 'text';
    final isSuspicious = data['isSuspicious'] == true;

    if (type == 'call_summary') {
      return (data['text'] as String?)?.trim() ?? 'Call activity';
    }

    if (isSuspicious) {
      return 'A suspicious message was hidden.';
    }

    switch (type) {
      case 'image':
        return 'Sent a photo';
      case 'gif':
        return 'Sent a GIF';
      case 'file':
        final fileName = (data['fileName'] as String?)?.trim();
        return fileName != null && fileName.isNotEmpty
            ? 'Sent a file: $fileName'
            : 'Sent a file';
      case 'text':
        final text = (data['text'] as String?)?.trim() ?? '';
        if (text.isNotEmpty) return text;
        return '';
      default:
        return (data['text'] as String?)?.trim() ?? '';
    }
  }

  Future<void> stop() async {
    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _settingsSubscription?.cancel();
    _settingsSubscription = null;
    _initializedSnapshot = false;
    _activeChatId = null;
    _seenMessageIds.clear();
    _mutedSenderIds.clear();
    _blockedSenderIds.clear();
    _senderNameCache.clear();
    _previewCache.clear();
    await _syncNativeNotificationPreferences();
  }
}
