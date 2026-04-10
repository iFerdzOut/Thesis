// ignore_for_file: avoid_print

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'ai_detection_service.dart';
import 'e2ee_service.dart';
import 'feedback_database_service.dart';
import 'fcm_chat_service.dart';
import 'sms_storage_service.dart';
import 'user_profile_service.dart';

class OnlineChatService {
  static const Duration onlinePresenceTimeout = Duration(minutes: 2);
  static const Duration _conversationActivityBackfillCooldown =
      Duration(minutes: 15);
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final AIDetectionService _aiDetectionService = AIDetectionService();
  final FeedbackDatabaseService _feedbackDb = FeedbackDatabaseService();
  final FcmChatService _fcmChatService = FcmChatService();
  final SmsStorageService _smsStorageService = SmsStorageService();
  final E2eeService _e2eeService = E2eeService();
  final UserProfileService _userProfileService = UserProfileService();
  Future<void>? _conversationActivityBackfillFuture;
  String? _conversationActivityBackfillUserId;
  DateTime? _lastConversationActivityBackfillAt;

  static String normalizePresenceMode(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'invisible':
        return 'invisible';
      case 'dnd':
        return 'dnd';
      case 'idle':
        return 'idle';
      case 'online':
      default:
        return 'online';
    }
  }

  String get currentUserId => _auth.currentUser?.uid ?? '';

  String getChatId(String otherUserId) {
    final ids = [currentUserId, otherUserId]..sort();
    return ids.join('_');
  }

  Future<String> getCurrentUserDisplayName() async {
    return _userProfileService.getCurrentUserDisplayName();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> getMessages(String otherUserId) {
    final chatId = getChatId(otherUserId);
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .snapshots();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> getUserChats() {
    return _firestore
        .collection('chats')
        .where('participants', arrayContains: currentUserId)
        .snapshots();
  }

  Future<void> scheduleConversationActivityBackfillIfNeeded({
    bool force = false,
  }) async {
    if (currentUserId.isEmpty) return;
    final now = DateTime.now();
    if (!force &&
        _conversationActivityBackfillUserId == currentUserId &&
        _lastConversationActivityBackfillAt != null &&
        now.difference(_lastConversationActivityBackfillAt!) <
            _conversationActivityBackfillCooldown) {
      return;
    }
    unawaited(ensureConversationActivityFields(force: force));
  }

  Future<void> ensureConversationActivityFields({bool force = false}) async {
    if (currentUserId.isEmpty) return;
    if (!force &&
        _conversationActivityBackfillUserId == currentUserId &&
        _lastConversationActivityBackfillAt != null &&
        DateTime.now().difference(_lastConversationActivityBackfillAt!) <
            _conversationActivityBackfillCooldown) {
      return;
    }
    if (_conversationActivityBackfillUserId == currentUserId &&
        _conversationActivityBackfillFuture != null) {
      await _conversationActivityBackfillFuture;
      return;
    }

    final future = _backfillConversationActivityFields();
    _conversationActivityBackfillUserId = currentUserId;
    _conversationActivityBackfillFuture = future;
    try {
      await future;
      _lastConversationActivityBackfillAt = DateTime.now();
    } finally {
      if (identical(_conversationActivityBackfillFuture, future)) {
        _conversationActivityBackfillFuture = null;
      }
    }
  }

  CollectionReference<Map<String, dynamic>> _chatSettingsCollection(
    String userId,
  ) {
    return _firestore.collection('users').doc(userId).collection('chat_settings');
  }

  DocumentReference<Map<String, dynamic>> _chatSettingsRef(String otherUserId) {
    return _chatSettingsCollection(currentUserId).doc(otherUserId);
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> getChatSettings() {
    if (currentUserId.isEmpty) {
      return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
    }
    return _chatSettingsCollection(currentUserId).snapshots();
  }

  Future<Map<String, dynamic>> getChatRelationship(String otherUserId) async {
    if (currentUserId.isEmpty || otherUserId.isEmpty) {
      return const <String, dynamic>{
        'mutedNotifications': false,
        'blockedByMe': false,
        'blockedByThem': false,
        'manualUnread': false,
      };
    }

    final mySettingsDoc = await _chatSettingsRef(otherUserId).get();
    final theirSettingsDoc =
        await _chatSettingsCollection(otherUserId).doc(currentUserId).get();

    final mySettings = mySettingsDoc.data() ?? const <String, dynamic>{};
    final theirSettings = theirSettingsDoc.data() ?? const <String, dynamic>{};

    return <String, dynamic>{
      'mutedNotifications': mySettings['mutedNotifications'] == true,
      'blockedByMe': mySettings['blocked'] == true,
      'blockedByThem': theirSettings['blocked'] == true,
      'manualUnread': mySettings['manualUnread'] == true,
    };
  }

  Future<void> setConversationMuted({
    required String otherUserId,
    required bool muted,
  }) async {
    if (currentUserId.isEmpty || otherUserId.isEmpty) return;
    await _chatSettingsRef(otherUserId).set({
      'mutedNotifications': muted,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> setConversationBlocked({
    required String otherUserId,
    required bool blocked,
    String? otherName,
  }) async {
    if (currentUserId.isEmpty || otherUserId.isEmpty) return;
    await _chatSettingsRef(otherUserId).set({
      'blocked': blocked,
      if (otherName != null && otherName.trim().isNotEmpty) 'name': otherName,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> markConversationUnread(String otherUserId) async {
    if (currentUserId.isEmpty || otherUserId.isEmpty) return;
    final chatId = getChatId(otherUserId);

    await _chatSettingsRef(otherUserId).set({
      'manualUnread': true,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await _firestore.collection('chats').doc(chatId).set({
      'lastMessageIsRead': false,
    }, SetOptions(merge: true));
  }

  Future<void> assertMessagingAllowed(String otherUserId) async {
    if (currentUserId.isEmpty || otherUserId.isEmpty) {
      throw Exception('Chat is unavailable right now.');
    }

    final relationship = await getChatRelationship(otherUserId);
    if (relationship['blockedByMe'] == true) {
      throw Exception('You blocked this user.');
    }
    if (relationship['blockedByThem'] == true) {
      throw Exception('This user is not accepting messages from you.');
    }
  }

  Future<void> hideConversation(String otherUserId) async {
    if (currentUserId.isEmpty || otherUserId.isEmpty) return;
    final chatId = getChatId(otherUserId);
    await _firestore.collection('chats').doc(chatId).set({
      'hiddenFor': {
        currentUserId: true,
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Map<String, dynamic> _messageActivityFields({
    required int clientMs,
    String? lastMessageId,
  }) {
    return <String, dynamic>{
      'lastMessageAt': FieldValue.serverTimestamp(),
      'lastMessageAtClientMs': clientMs,
      if (lastMessageId != null && lastMessageId.trim().isNotEmpty)
        'lastMessageClientMessageId': lastMessageId.trim(),
    };
  }

  Map<String, dynamic> _clearedEncryptedSummaryFields() {
    return <String, dynamic>{
      'lastMessageCipherText': FieldValue.delete(),
      'lastMessageDeviceEnvelopes': FieldValue.delete(),
      'lastMessageCacheKey': FieldValue.delete(),
      'lastMessageAlgorithm': FieldValue.delete(),
      'lastMessageE2eeMessageType': FieldValue.delete(),
      'lastMessageNonce': FieldValue.delete(),
      'lastMessageMac': FieldValue.delete(),
      'lastMessageSenderPublicKey': FieldValue.delete(),
      'lastMessageReceiverPublicKey': FieldValue.delete(),
      'lastMessageSessionId': FieldValue.delete(),
      'lastMessageSessionVersion': FieldValue.delete(),
      'lastMessageSessionPeerId': FieldValue.delete(),
      'lastMessageSessionAlgorithm': FieldValue.delete(),
      'lastMessageSessionLocalPublicKey': FieldValue.delete(),
      'lastMessageSessionPeerPublicKey': FieldValue.delete(),
      'lastMessageIsSuspicious': FieldValue.delete(),
    };
  }

  String _safeConversationLabelForMessage(Map<String, dynamic> messageData) {
    final type = messageData['type']?.toString().trim() ?? 'text';
    final isSuspicious = messageData['isSuspicious'] == true;
    final isEncryptedText = type == 'text' && messageData['e2ee'] == true;

    if (isEncryptedText) {
      return isSuspicious
          ? 'Suspicious encrypted message'
          : 'Encrypted message';
    }

    switch (type) {
      case 'image':
        return 'Photo';
      case 'gif':
        return 'GIF';
      case 'file':
        return 'File';
      case 'call_summary':
        final summary = messageData['text']?.toString().trim() ?? '';
        return summary.isNotEmpty ? summary : 'Call';
      case 'deleted':
        return 'Message deleted';
      default:
        return 'Message';
    }
  }

  bool _summaryNeedsReconcile(Map<String, dynamic> data) {
    final lastMessageId = data['lastMessageClientMessageId']?.toString().trim() ?? '';
    final lastMessageSenderId = data['lastMessageSenderId']?.toString().trim() ?? '';
    final lastMessageType = data['lastMessageType']?.toString().trim() ?? '';
    return data['lastMessageAt'] == null ||
        data['lastMessageAtClientMs'] == null ||
        lastMessageId.isEmpty ||
        lastMessageSenderId.isEmpty ||
        lastMessageType.isEmpty;
  }

  int _conversationActivitySortMs(Map<String, dynamic> data) {
    final lastMessageAtMs =
        _parseDateTime(data['lastMessageAt'])?.millisecondsSinceEpoch ?? 0;
    final lastMessageAtClientMs =
        _parseDateTime(data['lastMessageAtClientMs'])?.millisecondsSinceEpoch ??
            0;
    final updatedAtMs =
        _parseDateTime(data['updatedAt'])?.millisecondsSinceEpoch ?? 0;
    return [lastMessageAtMs, lastMessageAtClientMs, updatedAtMs].reduce(
      (value, element) => value > element ? value : element,
    );
  }

  String _resolveOtherUserIdFromParticipants(
    dynamic rawParticipants,
    String? fallback,
  ) {
    final participants = (rawParticipants is Iterable)
        ? rawParticipants
            .map((value) => value?.toString().trim() ?? '')
            .where((value) => value.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    for (final participant in participants) {
      if (participant != currentUserId) {
        return participant;
      }
    }
    return fallback?.trim() ?? '';
  }

  Future<void> upsertConversationSummaryFromMessage({
    required String otherUserId,
    required Map<String, dynamic> messageData,
    required String lastMessageId,
    int? activityClientMs,
    String? currentUserDisplayName,
    String? otherUserDisplayName,
    bool clearHiddenFor = true,
  }) async {
    if (currentUserId.isEmpty || otherUserId.trim().isEmpty) return;

    final chatId = getChatId(otherUserId);
    final senderId =
        messageData['senderId']?.toString().trim().isNotEmpty == true
            ? messageData['senderId'].toString().trim()
            : currentUserId;
    final receiverId =
        messageData['receiverId']?.toString().trim().isNotEmpty == true
            ? messageData['receiverId'].toString().trim()
            : (senderId == currentUserId ? otherUserId : currentUserId);
    final type = messageData['type']?.toString().trim() ?? 'text';
    final isEncryptedText = type == 'text' && messageData['e2ee'] == true;
    final resolvedCurrentName =
        currentUserDisplayName?.trim().isNotEmpty == true
            ? currentUserDisplayName!.trim()
            : await getCurrentUserDisplayName();
    final resolvedOtherName =
        otherUserDisplayName?.trim().isNotEmpty == true
            ? otherUserDisplayName!.trim()
            : (senderId == otherUserId &&
                    messageData['senderName']?.toString().trim().isNotEmpty ==
                        true)
                ? messageData['senderName'].toString().trim()
                : await _userProfileService.fetchDisplayName(
                    otherUserId,
                    fallback: otherUserId,
                  );
    final resolvedActivityClientMs = activityClientMs ??
        _resolveMessageActivityTime(messageData).millisecondsSinceEpoch;
    final summary = <String, dynamic>{
      'participants': [currentUserId, otherUserId],
      'participantNames': {
        currentUserId: resolvedCurrentName,
        otherUserId: resolvedOtherName,
      },
      if (clearHiddenFor) 'hiddenFor.$currentUserId': FieldValue.delete(),
      if (clearHiddenFor) 'hiddenFor.$otherUserId': FieldValue.delete(),
      'lastMessage': _safeConversationLabelForMessage(messageData),
      'lastMessageE2ee': isEncryptedText,
      'lastMessageSenderId': senderId,
      'lastMessageReceiverId': receiverId,
      'lastMessageIsRead': false,
      'lastMessageType': isEncryptedText ? 'encrypted_text' : type,
      'updatedAt': FieldValue.serverTimestamp(),
      ..._messageActivityFields(
        clientMs: resolvedActivityClientMs > 0
            ? resolvedActivityClientMs
            : DateTime.now().millisecondsSinceEpoch,
        lastMessageId: lastMessageId,
      ),
      ..._clearedEncryptedSummaryFields(),
    };

    if (isEncryptedText) {
      summary.addAll(<String, dynamic>{
        'lastMessageCipherText': messageData['cipherText'],
        'lastMessageDeviceEnvelopes': messageData['e2eeDeviceEnvelopes'],
        'lastMessageCacheKey': messageData['e2eeCacheKey'],
        'lastMessageAlgorithm': messageData['e2eeAlgorithm'],
        'lastMessageE2eeMessageType': messageData['e2eeMessageType'],
        'lastMessageNonce': messageData['e2eeNonce'],
        'lastMessageMac': messageData['e2eeMac'],
        'lastMessageSenderPublicKey': messageData['senderPublicKey'],
        'lastMessageReceiverPublicKey': messageData['receiverPublicKey'],
        'lastMessageSessionId': messageData['e2eeSessionId'],
        'lastMessageSessionVersion': messageData['e2eeSessionVersion'],
        'lastMessageSessionPeerId': messageData['e2eeSessionPeerId'],
        'lastMessageSessionAlgorithm': messageData['e2eeSessionAlgorithm'],
        'lastMessageSessionLocalPublicKey':
            messageData['e2eeSessionLocalPublicKey'],
        'lastMessageSessionPeerPublicKey':
            messageData['e2eeSessionPeerPublicKey'],
        'lastMessageIsSuspicious': messageData['isSuspicious'] == true,
      });
    }

    await _firestore
        .collection('chats')
        .doc(chatId)
        .set(summary, SetOptions(merge: true));
  }

  Future<void> reconcileConversationSummaryFromLatestMessage({
    required String otherUserId,
    String? chatId,
    Map<String, dynamic>? existingChatData,
  }) async {
    if (currentUserId.isEmpty || otherUserId.trim().isEmpty) return;

    final resolvedChatId = chatId?.trim().isNotEmpty == true
        ? chatId!.trim()
        : getChatId(otherUserId);
    final chatRef = _firestore.collection('chats').doc(resolvedChatId);
    final chatDoc =
        existingChatData == null ? await chatRef.get() : null;
    final chatData = existingChatData ??
        (chatDoc?.data() ?? const <String, dynamic>{});
    final latestMessageDoc = await _fetchLatestMessageCandidate(chatRef) ??
        await _fetchLatestMessageFallback(chatRef);
    if (latestMessageDoc == null) {
      return;
    }
    final latestData = Map<String, dynamic>.from(latestMessageDoc.data());
    final latestMessageId =
        latestData['clientMessageId']?.toString().trim().isNotEmpty == true
            ? latestData['clientMessageId'].toString().trim()
            : latestMessageDoc.id;
    final latestActivity = _resolveMessageActivityTime(latestData);
    final latestActivityMs =
        latestActivity.millisecondsSinceEpoch > 0
            ? latestActivity.millisecondsSinceEpoch
            : DateTime.now().millisecondsSinceEpoch;
    final summaryActivityMs = _conversationActivitySortMs(chatData);
    final currentLastMessageId =
        chatData['lastMessageClientMessageId']?.toString().trim() ?? '';
    final needsUpdate = _summaryNeedsReconcile(chatData) ||
        currentLastMessageId != latestMessageId ||
        summaryActivityMs <= 0 ||
        latestActivityMs > summaryActivityMs;

    if (!needsUpdate) {
      return;
    }

    final participantNames = Map<String, dynamic>.from(
      chatData['participantNames'] ?? const <String, dynamic>{},
    );
    final currentDisplayName =
        participantNames[currentUserId]?.toString().trim().isNotEmpty == true
            ? participantNames[currentUserId].toString().trim()
            : null;
    final otherDisplayName =
        participantNames[otherUserId]?.toString().trim().isNotEmpty == true
            ? participantNames[otherUserId].toString().trim()
            : null;

    await upsertConversationSummaryFromMessage(
      otherUserId: otherUserId,
      messageData: latestData,
      lastMessageId: latestMessageId,
      activityClientMs: latestActivityMs,
      currentUserDisplayName: currentDisplayName,
      otherUserDisplayName: otherDisplayName,
    );
  }

  Future<void> _backfillConversationActivityFields() async {
    final uid = currentUserId;
    if (uid.isEmpty) return;

    final chatSnapshot = await _firestore
        .collection('chats')
        .where('participants', arrayContains: uid)
        .get();

    for (final doc in chatSnapshot.docs) {
      final data = doc.data();
      final otherUserId =
          _resolveOtherUserIdFromParticipants(data['participants'], null);
      if (otherUserId.isEmpty) {
        continue;
      }
      try {
        await reconcileConversationSummaryFromLatestMessage(
          otherUserId: otherUserId,
          chatId: doc.id,
          existingChatData: data,
        );
      } catch (_) {}
    }
  }

  Future<QueryDocumentSnapshot<Map<String, dynamic>>?> _fetchLatestMessageCandidate(
    DocumentReference<Map<String, dynamic>> chatRef,
  ) async {
    QueryDocumentSnapshot<Map<String, dynamic>>? best;

    Future<void> considerQuery(String field) async {
      try {
        final snapshot = await chatRef
            .collection('messages')
            .orderBy(field, descending: true)
            .limit(1)
            .get();
        if (snapshot.docs.isEmpty) {
          return;
        }
        final candidate = snapshot.docs.first;
        if (best == null) {
          best = candidate;
          return;
        }
        final bestTs = _resolveMessageActivityTime(best!.data());
        final candidateTs = _resolveMessageActivityTime(candidate.data());
        if (candidateTs.isAfter(bestTs)) {
          best = candidate;
        }
      } catch (_) {}
    }

    await considerQuery('timestamp');
    await considerQuery('editedAt');
    await considerQuery('updatedAt');
    return best;
  }

  Future<QueryDocumentSnapshot<Map<String, dynamic>>?> _fetchLatestMessageFallback(
    DocumentReference<Map<String, dynamic>> chatRef,
  ) async {
    final messageSnapshot = await chatRef.collection('messages').get();
    if (messageSnapshot.docs.isEmpty) {
      return null;
    }
    return messageSnapshot.docs.reduce((latest, candidate) {
      final latestTs = _resolveMessageActivityTime(latest.data());
      final candidateTs = _resolveMessageActivityTime(candidate.data());
      return candidateTs.isAfter(latestTs) ? candidate : latest;
    });
  }

  DateTime? _parseDateTime(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) {
      final parsedInt = int.tryParse(raw);
      if (parsedInt != null) {
        return DateTime.fromMillisecondsSinceEpoch(parsedInt);
      }
      return DateTime.tryParse(raw);
    }
    return null;
  }

  DateTime _resolveMessageActivityTime(Map<String, dynamic> data) {
    return _parseDateTime(data['timestamp']) ??
        _parseDateTime(data['editedAt']) ??
        _parseDateTime(data['updatedAt']) ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> sendMessage({
    required String receiverId,
    required String text,
    String? receiverName,
  }) async {
    if (currentUserId.isEmpty || text.trim().isEmpty) return;
    await assertMessagingAllowed(receiverId);

    final chatId = getChatId(receiverId);
    final trimmedText = text.trim();
    final senderName = await getCurrentUserDisplayName();
    final receiverDisplayName = await _userProfileService.fetchDisplayName(
      receiverId,
      fallback: (receiverName?.trim().isNotEmpty ?? false)
          ? receiverName!.trim()
          : receiverId,
    );
    await _e2eeService.ensureIdentityForCurrentUser();
    final isSuspicious = await _aiDetectionService.detectSmishing(
      trimmedText,
      sender: currentUserId,
    );
    final encryptedEnvelope = await _e2eeService.encryptTextEnvelope(
      receiverId: receiverId,
      plaintext: trimmedText,
    );
    final activityClientMs = DateTime.now().millisecondsSinceEpoch;
    final clientMessageId =
        encryptedEnvelope['clientMessageId']?.toString().trim().isNotEmpty ==
                true
            ? encryptedEnvelope['clientMessageId'].toString().trim()
            : _firestore.collection('chats').doc().id;
    await _e2eeService.seedDecryptedTextCache(
      senderId: currentUserId,
      receiverId: receiverId,
      plaintext: trimmedText,
      nonce: encryptedEnvelope['e2eeNonce']?.toString(),
      mac: encryptedEnvelope['e2eeMac']?.toString(),
      cacheKey: encryptedEnvelope['e2eeCacheKey']?.toString(),
      clientMessageId: clientMessageId,
    );

    final messageData = {
      'clientMessageId': clientMessageId,
      'senderId': currentUserId,
      'senderName': senderName,
      'receiverId': receiverId,
      'text': '',
      'type': 'text',
      'isSuspicious': isSuspicious,
      'isReported': false,
      'isRead': false,
      'isDeleted': false,
      'editCount': 0,
      'timestamp': FieldValue.serverTimestamp(),
      ...encryptedEnvelope,
    };

    final messageRef = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(clientMessageId);
    await messageRef.set(messageData, SetOptions(merge: true));
    await _e2eeService.finalizeOutgoingTextProjection(
      senderId: currentUserId,
      receiverId: receiverId,
      messageId: messageRef.id,
      clientMessageId: clientMessageId,
      plaintext: trimmedText,
      cacheKey: encryptedEnvelope['e2eeCacheKey']?.toString(),
      nonce: encryptedEnvelope['e2eeNonce']?.toString(),
      mac: encryptedEnvelope['e2eeMac']?.toString(),
      messageType: 'text',
      timestampMs: activityClientMs,
    );

    await upsertConversationSummaryFromMessage(
      otherUserId: receiverId,
      messageData: messageData,
      lastMessageId: clientMessageId,
      activityClientMs: activityClientMs,
      currentUserDisplayName: senderName,
      otherUserDisplayName: receiverDisplayName,
    );

    await _fcmChatService.notifyIncomingChat(
      receiverId: receiverId,
      chatId: chatId,
      messageId: messageRef.id,
      senderName: senderName,
      preview: isSuspicious
          ? 'A suspicious message was hidden.'
          : 'Encrypted message',
      type: 'text',
    );
  }

  Future<void> sendCallSummary({
    required String receiverId,
    required String callId,
    required bool isVideo,
    required int durationSeconds,
    String? receiverName,
    String? senderIdOverride,
    String? senderNameOverride,
  }) async {
    if (currentUserId.isEmpty || callId.isEmpty) return;

    final chatId = getChatId(receiverId);
    final currentUserDisplayName = await getCurrentUserDisplayName();
    final receiverDisplayName = await _userProfileService.fetchDisplayName(
      receiverId,
      fallback: (receiverName?.trim().isNotEmpty ?? false)
          ? receiverName!.trim()
          : receiverId,
    );
    final summarySenderId = (senderIdOverride?.trim().isNotEmpty ?? false)
        ? senderIdOverride!.trim()
        : currentUserId;
    final summarySenderName = (senderNameOverride?.trim().isNotEmpty ?? false)
        ? senderNameOverride!.trim()
        : currentUserDisplayName;
    final summaryReceiverId =
        summarySenderId == currentUserId ? receiverId : currentUserId;
    final minutes = (durationSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (durationSeconds % 60).toString().padLeft(2, '0');
    final durationLabel = '$minutes:$seconds';
    final callLabel = isVideo ? 'Video call' : 'Voice call';
    final summaryText = '$callLabel ($durationLabel)';
    final activityClientMs = DateTime.now().millisecondsSinceEpoch;

    await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc('call_summary_$callId')
        .set({
      'senderId': summarySenderId,
      'senderName': summarySenderName,
      'receiverId': summaryReceiverId,
      'text': summaryText,
      'type': 'call_summary',
      'callMode': isVideo ? 'video' : 'voice',
      'durationSeconds': durationSeconds,
      'isSuspicious': false,
      'isReported': false,
      'isRead': false,
      'isDeleted': false,
      'editCount': 0,
      'timestamp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await upsertConversationSummaryFromMessage(
      otherUserId: receiverId,
      messageData: <String, dynamic>{
        'senderId': summarySenderId,
        'senderName': summarySenderName,
        'receiverId': summaryReceiverId,
        'text': summaryText,
        'type': 'call_summary',
        'isRead': false,
      },
      lastMessageId: 'call_summary_$callId',
      activityClientMs: activityClientMs,
      currentUserDisplayName: currentUserDisplayName,
      otherUserDisplayName: receiverDisplayName,
    );
  }

  // ── Edit message (max 3 times, sender only) ───────────────────────────
  Future<void> editMessage({
    required String otherUserId,
    required String messageId,
    required String newText,
    required int currentEditCount,
  }) async {
    await assertMessagingAllowed(otherUserId);
    if (currentEditCount >= 3) {
      throw Exception('Message can only be edited 3 times.');
    }
    if (newText.trim().isEmpty) {
      throw Exception('Message cannot be empty.');
    }

    final chatId = getChatId(otherUserId);
    final isSuspicious = await _aiDetectionService.detectSmishing(
      newText.trim(),
      sender: currentUserId,
    );
    final messageRef = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    final messageDoc = await messageRef.get();
    final existingData = messageDoc.data() ?? <String, dynamic>{};

    if (existingData['e2ee'] == true) {
      await _e2eeService.ensureIdentityForCurrentUser();
      final encryptedEnvelope = await _e2eeService.encryptTextEnvelope(
        receiverId: otherUserId,
        plaintext: newText.trim(),
      );
      final refreshedClientMessageId =
          encryptedEnvelope['clientMessageId']?.toString().trim().isNotEmpty ==
                  true
              ? encryptedEnvelope['clientMessageId'].toString().trim()
              : existingData['clientMessageId']?.toString();
      await _e2eeService.seedDecryptedTextCache(
        senderId: currentUserId,
        receiverId: otherUserId,
        plaintext: newText.trim(),
        nonce: encryptedEnvelope['e2eeNonce']?.toString(),
        mac: encryptedEnvelope['e2eeMac']?.toString(),
        cacheKey: encryptedEnvelope['e2eeCacheKey']?.toString(),
        clientMessageId: refreshedClientMessageId,
      );

      await messageRef.update({
        'text': '',
        if (refreshedClientMessageId != null &&
            refreshedClientMessageId.trim().isNotEmpty)
          'clientMessageId': refreshedClientMessageId.trim(),
        'isSuspicious': isSuspicious,
        'editCount': FieldValue.increment(1),
        'editedAt': FieldValue.serverTimestamp(),
        ...encryptedEnvelope,
      });
      final existingTimestampMs = _resolveMessageActivityTime(
        Map<String, dynamic>.from(existingData),
      ).millisecondsSinceEpoch;
      await _e2eeService.finalizeOutgoingTextProjection(
        senderId: currentUserId,
        receiverId: otherUserId,
        messageId: messageId,
        clientMessageId: refreshedClientMessageId,
        plaintext: newText.trim(),
        cacheKey: encryptedEnvelope['e2eeCacheKey']?.toString(),
        nonce: encryptedEnvelope['e2eeNonce']?.toString(),
        mac: encryptedEnvelope['e2eeMac']?.toString(),
        messageType: 'text',
        timestampMs: existingTimestampMs > 0
            ? existingTimestampMs
            : DateTime.now().millisecondsSinceEpoch,
      );

      final chatId = getChatId(otherUserId);
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();
      if (chatDoc.exists &&
          chatDoc.data()?['lastMessageSenderId'] == currentUserId) {
        final activityClientMs = DateTime.now().millisecondsSinceEpoch;
        await upsertConversationSummaryFromMessage(
          otherUserId: otherUserId,
          messageData: <String, dynamic>{
            ...Map<String, dynamic>.from(existingData),
            ...encryptedEnvelope,
            'senderId': currentUserId,
            'receiverId': otherUserId,
            'senderName': await getCurrentUserDisplayName(),
            'text': '',
            'type': 'text',
            'e2ee': true,
            'isSuspicious': isSuspicious,
            if (refreshedClientMessageId != null &&
                refreshedClientMessageId.trim().isNotEmpty)
              'clientMessageId': refreshedClientMessageId.trim(),
          },
          lastMessageId:
              refreshedClientMessageId?.trim().isNotEmpty == true
                  ? refreshedClientMessageId!.trim()
                  : messageId,
          activityClientMs: activityClientMs,
        );
      }
    } else {
      await messageRef.update({
        'text': newText.trim(),
        'isSuspicious': isSuspicious,
        'editCount': FieldValue.increment(1),
        'editedAt': FieldValue.serverTimestamp(),
      });
    }

    print(
        '[OnlineChatService] Message edited (count: ${currentEditCount + 1})');
  }

  // ── Delete message (soft delete — shows "Message deleted") ────────────
  Future<void> deleteMessage({
    required String otherUserId,
    required String messageId,
    required bool isMyMessage,
  }) async {
    final chatId = getChatId(otherUserId);

    if (isMyMessage) {
      // Sender can fully soft-delete
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update({
        'isDeleted': true,
        'text': '',
        'type': 'deleted',
      });
    } else {
      // Receiver can only delete for themselves (hide from their view)
      await _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(messageId)
          .update({
        'deletedFor': FieldValue.arrayUnion([currentUserId]),
      });
    }

    print('[OnlineChatService] Message deleted');
  }

  // ── Report to Quarantine ──────────────────────────────────────────────
  Future<void> reportMessageToQuarantine({
    required String sender,
    required String message,
    required String source,
    String? messageDocPath,
  }) async {
    if (currentUserId.isEmpty) throw Exception('No logged-in user found');

    await _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('quarantine')
        .add({
      'sender': sender,
      'message': message,
      'source': source,
      'messageDocPath': messageDocPath,
      'restoreMode': source == 'online' &&
              messageDocPath != null &&
              messageDocPath.isNotEmpty
          ? 'messageDoc'
          : null,
      'reportedAt': FieldValue.serverTimestamp(),
    });

    if (messageDocPath != null && messageDocPath.isNotEmpty) {
      await _firestore.doc(messageDocPath).update({'isReported': true});
    }

    if (source == 'false_negative_sms' || source == 'false_negative_online') {
      await _feedbackDb.saveFalseNegative(
        message: message,
        source: source.replaceFirst('false_negative_', ''),
        sender: sender,
      );
    } else {
      await _feedbackDb.saveConfirmedSmishing(
        message: message,
        source: source,
        sender: sender,
      );
    }
  }

  // ── False Positive ────────────────────────────────────────────────────
  Future<void> removeFalsePositiveFromQuarantine(String docId) async {
    if (currentUserId.isEmpty) return;

    final doc = await _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('quarantine')
        .doc(docId)
        .get();

    if (doc.exists) {
      final data = doc.data()!;
      final restoreMode = data['restoreMode']?.toString() ?? '';
      final messageDocPath = data['messageDocPath']?.toString() ?? '';

      if (restoreMode == 'messageDoc' && messageDocPath.isNotEmpty) {
        try {
          await _firestore.doc(messageDocPath).set({
            'isReported': false,
            'isSuspicious': false,
          }, SetOptions(merge: true));
        } catch (_) {}
      } else if (restoreMode == 'smsThread') {
        final sender = data['sender']?.toString() ?? '';
        final message = data['message']?.toString() ?? '';
        final simSlot = (data['simSlot'] as num?)?.toInt() ?? 0;
        final storedTime = DateTime.tryParse(data['time']?.toString() ?? '');
        if (sender.isNotEmpty && message.isNotEmpty) {
          await _smsStorageService.saveMessage(
            SmsMessage(
              sender: sender,
              body: message,
              time: storedTime ?? DateTime.now(),
              isSuspicious: false,
              simSlot: simSlot,
            ),
          );
        }
      }

      await _feedbackDb.saveFalsePositive(
        message: data['message'] ?? '',
        source: data['source'] ?? 'unknown',
        sender: data['sender'] ?? '',
      );
    }

    final quarantineData = doc.data();
    final quarantineSource = quarantineData == null
        ? ''
        : (quarantineData['source']?.toString() ?? '');
    final smsSenderForReconcile = doc.exists && quarantineSource == 'sms'
        ? quarantineData == null
            ? null
            : quarantineData['sender']?.toString()
        : null;

    await _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('quarantine')
        .doc(docId)
        .delete();

    if (smsSenderForReconcile != null && smsSenderForReconcile.isNotEmpty) {
      await _smsStorageService.reconcileThreadMetadataForSender(
        smsSenderForReconcile,
      );
    }
  }

  Future<void> deleteQuarantineMessage(String docId) async {
    if (currentUserId.isEmpty || docId.isEmpty) return;

    String? smsSender;
    try {
      final doc = await _firestore
          .collection('users')
          .doc(currentUserId)
          .collection('quarantine')
          .doc(docId)
          .get();
      final data = doc.data();
      if (data?['source'] == 'sms') {
        smsSender = data?['sender']?.toString();
      }
    } catch (_) {}

    await _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('quarantine')
        .doc(docId)
        .delete();

    if (smsSender != null && smsSender.isNotEmpty) {
      await _smsStorageService.reconcileThreadMetadataForSender(smsSender);
    }
  }

  // ── Typing Indicators ─────────────────────────────────────────────────
  Future<void> setTyping({
    required String otherUserId,
    required bool isTyping,
  }) async {
    if (currentUserId.isEmpty) return;
    final chatId = getChatId(otherUserId);
    await _firestore.collection('chats').doc(chatId).set({
      'typing': {currentUserId: isTyping},
    }, SetOptions(merge: true));
  }

  Stream<bool> getIsTyping({required String otherUserId}) {
    final chatId = getChatId(otherUserId);
    return _firestore.collection('chats').doc(chatId).snapshots().map((doc) {
      if (!doc.exists) return false;
      final data = doc.data();
      final typingRaw = data?['typing'];
      final typing = typingRaw is Map ? typingRaw : null;
      return typing?[otherUserId] == true;
    });
  }

  // ── Read Receipts ─────────────────────────────────────────────────────
  Future<void> markMessagesAsRead(String otherUserId) async {
    if (currentUserId.isEmpty) return;
    final chatId = getChatId(otherUserId);

    final unread = await _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .where('receiverId', isEqualTo: currentUserId)
        .where('isRead', isEqualTo: false)
        .get();

    final batch = _firestore.batch();
    for (final doc in unread.docs) {
      batch.update(doc.reference, {'isRead': true});
    }
    await batch.commit();

    try {
      await _firestore.collection('chats').doc(chatId).set({
        'lastMessageIsRead': true,
      }, SetOptions(merge: true));
    } catch (_) {}

    try {
      await _chatSettingsRef(otherUserId).set({
        'manualUnread': false,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // ── Online Status ─────────────────────────────────────────────────────
  Future<void> setOnline() async {
    if (currentUserId.isEmpty) return;
    final userRef = _firestore.collection('users').doc(currentUserId);
    final userDoc = await userRef.get();
    final presenceMode =
        normalizePresenceMode(userDoc.data()?['presenceMode']?.toString());

    await userRef.set({
      'presenceMode': presenceMode,
      'isOnline': presenceMode != 'invisible',
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> setOffline() async {
    if (currentUserId.isEmpty) return;
    await _firestore.collection('users').doc(currentUserId).set({
      'isOnline': false,
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> setPresenceMode(String mode) async {
    if (currentUserId.isEmpty) return;
    final normalized = normalizePresenceMode(mode);
    await _firestore.collection('users').doc(currentUserId).set({
      'presenceMode': normalized,
      'isOnline': normalized != 'invisible',
      'lastSeen': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Stream<DocumentSnapshot> getUserStatus(String userId) {
    return _firestore.collection('users').doc(userId).snapshots();
  }

  static DateTime? parseLastSeen(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  static bool isPresenceFresh(dynamic rawLastSeen) {
    final lastSeen = parseLastSeen(rawLastSeen);
    if (lastSeen == null) return false;
    return DateTime.now().difference(lastSeen) <= onlinePresenceTimeout;
  }

  static bool computeEffectiveOnline(Map<String, dynamic>? data) {
    final raw = data ?? const <String, dynamic>{};
    final presenceMode =
        normalizePresenceMode(raw['presenceMode']?.toString());
    if (presenceMode == 'invisible') {
      return false;
    }

    final flaggedOnline = raw['isOnline'] == true;
    if (!flaggedOnline) {
      return false;
    }

    return isPresenceFresh(raw['lastSeen']);
  }

  // ── Quarantine Stream ─────────────────────────────────────────────────
  Stream<QuerySnapshot<Map<String, dynamic>>> getQuarantineMessages() {
    if (currentUserId.isEmpty) {
      return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
    }
    return _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('quarantine')
        .orderBy('reportedAt', descending: true)
        .snapshots();
  }
}
