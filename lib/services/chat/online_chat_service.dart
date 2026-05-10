// ignore_for_file: avoid_print

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../feedback/feedback_database_service.dart';
import 'fcm_chat_service.dart';
import '../../models/safety_status.dart';
import '../../smishing_detection_pipeline/pipeline_service.dart';
import '../sms/sms_storage_service.dart';
import '../auth/user_profile_service.dart';

class OnlineChatService {
  static const Duration onlinePresenceTimeout = Duration(minutes: 2);
  static const Duration typingIndicatorTimeout = Duration(seconds: 6);
  static const Duration _conversationActivityBackfillCooldown =
      Duration(minutes: 15);
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FeedbackDatabaseService _feedbackDb = FeedbackDatabaseService();
  final FcmChatService _fcmChatService = FcmChatService();
  final SmishingPipelineService _pipelineService = SmishingPipelineService();
  final SmsStorageService _smsStorageService = SmsStorageService();
  final UserProfileService _userProfileService = UserProfileService();
  final Set<String> _legacySummaryRepairCache = <String>{};
  final Set<String> _incomingOnlineScreeningInFlight = <String>{};
  Future<void>? _conversationActivityBackfillFuture;
  String? _conversationActivityBackfillUserId;
  DateTime? _lastConversationActivityBackfillAt;
  String? _legacySummaryRepairUserId;

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

  CollectionReference<Map<String, dynamic>> _quarantineCollection(
    String userId,
  ) {
    return _firestore.collection('users').doc(userId).collection('quarantine');
  }

  String buildSmsQuarantineMirrorId(String quarantineId) => quarantineId.trim();

  String getChatId(String otherUserId) {
    final ids = [currentUserId, otherUserId]..sort();
    return ids.join('_');
  }

  Future<String> getCurrentUserDisplayName() async {
    return _userProfileService.getCurrentUserDisplayName();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> getMessages(String otherUserId,
      {int limit = 100}) {
    final chatId = getChatId(otherUserId);
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: true)
        .limit(limit)
        .snapshots()
        .map((snapshot) {
      for (final doc in snapshot.docs) {
        unawaited(
          ensureIncomingMessageScreened(
            messageRef: doc.reference,
            data: doc.data(),
          ),
        );
      }
      return snapshot;
    });
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
    return _firestore
        .collection('users')
        .doc(userId)
        .collection('chat_settings');
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

  String _safeConversationLabelForMessage(Map<String, dynamic> messageData) {
    final type = messageData['type']?.toString().trim() ?? 'text';
    final isSuspicious = messageData['isSuspicious'] == true;

    switch (type) {
      case 'text':
        final text = messageData['text']?.toString().trim() ?? '';
        return text.isNotEmpty
            ? (isSuspicious ? 'Suspicious: $text' : text)
            : (isSuspicious ? 'Suspicious message' : 'Message');
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

  bool _summaryNeedsReconcile(
    Map<String, dynamic> data, {
    String? otherUserId,
  }) {
    final lastMessageId =
        data['lastMessageClientMessageId']?.toString().trim() ?? '';
    final lastMessageSenderId =
        data['lastMessageSenderId']?.toString().trim() ?? '';
    final lastMessageType = data['lastMessageType']?.toString().trim() ?? '';
    final resolvedOtherUserId = otherUserId?.trim() ?? '';
    final participants = (data['participants'] is Iterable)
        ? (data['participants'] as Iterable)
            .map((value) => value?.toString().trim() ?? '')
            .where((value) => value.isNotEmpty)
            .toList(growable: false)
        : const <String>[];
    final participantNames = data['participantNames'] is Map
        ? Map<String, dynamic>.from(data['participantNames'] as Map)
        : const <String, dynamic>{};
    final missingParticipants = resolvedOtherUserId.isNotEmpty &&
        (!participants.contains(currentUserId) ||
            !participants.contains(resolvedOtherUserId));
    final missingParticipantNames = resolvedOtherUserId.isNotEmpty &&
        ((participantNames[currentUserId]?.toString().trim().isEmpty ?? true) ||
            (participantNames[resolvedOtherUserId]?.toString().trim().isEmpty ??
                true));
    return data['lastMessageAt'] == null ||
        data['lastMessageAtClientMs'] == null ||
        lastMessageId.isEmpty ||
        lastMessageSenderId.isEmpty ||
        lastMessageType.isEmpty ||
        missingParticipants ||
        missingParticipantNames;
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
    final resolvedCurrentName =
        currentUserDisplayName?.trim().isNotEmpty == true
            ? currentUserDisplayName!.trim()
            : await getCurrentUserDisplayName();
    final resolvedOtherName = otherUserDisplayName?.trim().isNotEmpty == true
        ? otherUserDisplayName!.trim()
        : (senderId == otherUserId &&
                messageData['senderName']?.toString().trim().isNotEmpty == true)
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
      'lastMessageSenderId': senderId,
      'lastMessageReceiverId': receiverId,
      'lastMessageIsRead': false,
      'lastMessageType': type,
      'updatedAt': FieldValue.serverTimestamp(),
      ..._messageActivityFields(
        clientMs: resolvedActivityClientMs > 0
            ? resolvedActivityClientMs
            : DateTime.now().millisecondsSinceEpoch,
        lastMessageId: lastMessageId,
      ),
    };

    await _firestore
        .collection('chats')
        .doc(chatId)
        .set(summary, SetOptions(merge: true));
  }

  Future<void> ensureChatParticipants({
    required String otherUserId,
    String? currentUserDisplayName,
    String? otherUserDisplayName,
  }) async {
    if (currentUserId.isEmpty || otherUserId.trim().isEmpty) return;

    final resolvedCurrentName =
        currentUserDisplayName?.trim().isNotEmpty == true
            ? currentUserDisplayName!.trim()
            : await getCurrentUserDisplayName();
    final resolvedOtherName = otherUserDisplayName?.trim().isNotEmpty == true
        ? otherUserDisplayName!.trim()
        : await _userProfileService.fetchDisplayName(
            otherUserId,
            fallback: otherUserId,
          );

    await _firestore.collection('chats').doc(getChatId(otherUserId)).set({
      'participants': <String>[currentUserId, otherUserId],
      'participantNames': <String, String>{
        currentUserId: resolvedCurrentName,
        otherUserId: resolvedOtherName,
      },
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
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
    final chatDoc = existingChatData == null ? await chatRef.get() : null;
    final chatData =
        existingChatData ?? (chatDoc?.data() ?? const <String, dynamic>{});
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
    final latestActivityMs = latestActivity.millisecondsSinceEpoch > 0
        ? latestActivity.millisecondsSinceEpoch
        : DateTime.now().millisecondsSinceEpoch;
    final summaryActivityMs = _conversationActivitySortMs(chatData);
    final currentLastMessageId =
        chatData['lastMessageClientMessageId']?.toString().trim() ?? '';
    final needsUpdate = _summaryNeedsReconcile(
          chatData,
          otherUserId: otherUserId,
        ) ||
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

  Future<void> repairLegacyConversationSummariesForUsers(
    Iterable<String> otherUserIds,
  ) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;

    if (_legacySummaryRepairUserId != uid) {
      _legacySummaryRepairUserId = uid;
      _legacySummaryRepairCache.clear();
    }

    final pendingUserIds = otherUserIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && value != uid)
        .where((value) => !_legacySummaryRepairCache.contains(value))
        .toSet()
        .toList(growable: false);

    if (pendingUserIds.isEmpty) {
      return;
    }

    final currentDisplayName = await getCurrentUserDisplayName();
    for (final otherUserId in pendingUserIds) {
      _legacySummaryRepairCache.add(otherUserId);
      try {
        final chatId = getChatId(otherUserId);
        final chatRef = _firestore.collection('chats').doc(chatId);
        final chatDoc = await chatRef.get();
        final chatData = chatDoc.data();
        final shouldRepairMetadata = chatDoc.exists &&
            _summaryNeedsReconcile(
              chatData ?? const <String, dynamic>{},
              otherUserId: otherUserId,
            );

        if (shouldRepairMetadata) {
          final otherDisplayName = await _userProfileService.fetchDisplayName(
            otherUserId,
            fallback: otherUserId,
          );
          await chatRef.set({
            'participants': <String>[uid, otherUserId],
            'participantNames': <String, String>{
              uid: currentDisplayName,
              otherUserId: otherDisplayName,
            },
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }

        await reconcileConversationSummaryFromLatestMessage(
          otherUserId: otherUserId,
          chatId: chatId,
          existingChatData: chatData,
        );
      } catch (error) {
        _legacySummaryRepairCache.remove(otherUserId);
        print(
          '[OnlineChatService] legacy conversation repair failed for '
          '$otherUserId: $error',
        );
      }
    }
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

  Future<QueryDocumentSnapshot<Map<String, dynamic>>?>
      _fetchLatestMessageCandidate(
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

  Future<QueryDocumentSnapshot<Map<String, dynamic>>?>
      _fetchLatestMessageFallback(
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
    final chatId = getChatId(receiverId);
    final trimmedText = text.trim();
    if (currentUserId.isEmpty || trimmedText.isEmpty) return;

    final clientMessageId = _firestore.collection('chats').doc().id;

    try {
      await assertMessagingAllowed(receiverId);

      final senderName = await getCurrentUserDisplayName();
      final receiverDisplayName = await _userProfileService.fetchDisplayName(
        receiverId,
        fallback: (receiverName?.trim().isNotEmpty ?? false)
            ? receiverName!.trim()
            : receiverId,
      );
      // Detection failure is non-fatal — a model crash must never block sending.
      const bool isSuspicious = false;

      // Seed local plaintext cache so the sender can render what they typed
      // immediately without waiting for any background processing.
      final activityClientMs = DateTime.now().millisecondsSinceEpoch;

      await ensureChatParticipants(
        otherUserId: receiverId,
        currentUserDisplayName: senderName,
        otherUserDisplayName: receiverDisplayName,
      );

      final messageData = {
        'clientMessageId': clientMessageId,
        'senderId': currentUserId,
        'senderName': senderName,
        'receiverId': receiverId,
        'text': trimmedText,
        'type': 'text',
        'isSuspicious': isSuspicious,
        'isReported': false,
        'isRead': false,
        'isDeleted': false,
        'editCount': 0,
        'timestamp': FieldValue.serverTimestamp(),
      };

      final messageRef = _firestore
          .collection('chats')
          .doc(chatId)
          .collection('messages')
          .doc(clientMessageId);
      await messageRef.set(messageData);

      try {
        // Persist a final outgoing projection for consistent local rendering.
        await upsertConversationSummaryFromMessage(
          otherUserId: receiverId,
          messageData: messageData,
          lastMessageId: clientMessageId,
          activityClientMs: activityClientMs,
          currentUserDisplayName: senderName,
          otherUserDisplayName: receiverDisplayName,
        );
      } catch (e) {
        debugPrint(
          '[OnlineChatService] summary update failed after message send: $e',
        );
      }

      unawaited(
        _fcmChatService.notifyIncomingChat(
          receiverId: receiverId,
          chatId: chatId,
          messageId: messageRef.id,
          senderName: senderName,
          preview: trimmedText,
          type: 'text',
        ),
      );
    } catch (e) {
      // Re-throw to allow the UI to show a snackbar or other error.
      rethrow;
    }
  }

  Future<void> forwardMessage({
    required String receiverId,
    required String text,
    required String type,
    String? fileName,
    String? receiverName,
  }) async {
    final chatId = getChatId(receiverId);
    final trimmedText = text.trim();
    final normalizedType = type.trim().isEmpty ? 'text' : type.trim();
    if (currentUserId.isEmpty || trimmedText.isEmpty) return;

    final clientMessageId = _firestore.collection('chats').doc().id;
    await assertMessagingAllowed(receiverId);

    final senderName = await getCurrentUserDisplayName();
    final receiverDisplayName = await _userProfileService.fetchDisplayName(
      receiverId,
      fallback: (receiverName?.trim().isNotEmpty ?? false)
          ? receiverName!.trim()
          : receiverId,
    );
    final activityClientMs = DateTime.now().millisecondsSinceEpoch;

    await ensureChatParticipants(
      otherUserId: receiverId,
      currentUserDisplayName: senderName,
      otherUserDisplayName: receiverDisplayName,
    );

    final messageData = <String, dynamic>{
      'clientMessageId': clientMessageId,
      'senderId': currentUserId,
      'senderName': senderName,
      'receiverId': receiverId,
      'text': trimmedText,
      'type': normalizedType,
      if (fileName?.trim().isNotEmpty == true) 'fileName': fileName!.trim(),
      'isForwarded': true,
      'isSuspicious': false,
      'isReported': false,
      'isRead': false,
      'isDeleted': false,
      'editCount': 0,
      'timestamp': FieldValue.serverTimestamp(),
    };

    final messageRef = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(clientMessageId);
    await messageRef.set(messageData);

    await upsertConversationSummaryFromMessage(
      otherUserId: receiverId,
      messageData: messageData,
      lastMessageId: clientMessageId,
      activityClientMs: activityClientMs,
      currentUserDisplayName: senderName,
      otherUserDisplayName: receiverDisplayName,
    );

    unawaited(
      _fcmChatService.notifyIncomingChat(
        receiverId: receiverId,
        chatId: chatId,
        messageId: messageRef.id,
        senderName: senderName,
        preview: _forwardPreview(normalizedType, trimmedText, fileName),
        type: normalizedType,
      ),
    );
  }

  String _forwardPreview(String type, String text, String? fileName) {
    switch (type) {
      case 'image':
        return 'Forwarded a photo';
      case 'gif':
        return 'Forwarded a GIF';
      case 'file':
        final name = fileName?.trim();
        return name == null || name.isEmpty
            ? 'Forwarded a file'
            : 'Forwarded a file: $name';
      default:
        return text;
    }
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

    try {
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
    } catch (e) {
      // Call summary is best-effort; it should never crash the call flow.
      debugPrint('[OnlineChatService] sendCallSummary failed: $e');
      return;
    }

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
    // Detection failure is non-fatal — a model crash must never block editing.
    const bool isSuspicious = false;
    final messageRef = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);
    final messageDoc = await messageRef.get();
    final existingData = messageDoc.data() ?? <String, dynamic>{};

    final trimmed = newText.trim();
    await messageRef.update({
      'text': trimmed,
      'isSuspicious': isSuspicious,
      'editCount': FieldValue.increment(1),
      'editedAt': FieldValue.serverTimestamp(),
    });

    final chatDoc = await _firestore.collection('chats').doc(chatId).get();
    if (chatDoc.exists &&
        chatDoc.data()?['lastMessageSenderId'] == currentUserId) {
      final activityClientMs = DateTime.now().millisecondsSinceEpoch;
      await upsertConversationSummaryFromMessage(
        otherUserId: otherUserId,
        messageData: <String, dynamic>{
          ...Map<String, dynamic>.from(existingData),
          'senderId': currentUserId,
          'receiverId': otherUserId,
          'senderName': await getCurrentUserDisplayName(),
          'text': trimmed,
          'type': 'text',
          'isSuspicious': isSuspicious,
          'clientMessageId': existingData['clientMessageId'] ?? messageId,
        },
        lastMessageId: messageId,
        activityClientMs: activityClientMs,
      );
    }

    print(
        '[OnlineChatService] Message edited (count: ${currentEditCount + 1})');
  }

  // ── Delete message for current user only (vanish delete) ───────────────
  Future<void> deleteMessage({
    required String otherUserId,
    required String messageId,
    required bool isMyMessage,
  }) async {
    final chatId = getChatId(otherUserId);

    final messageRef = _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(messageId);

    if (isMyMessage) {
      await messageRef.set(<String, dynamic>{
        'isDeleted': true,
        'type': 'deleted',
        'messageType': 'deleted',
        'text': '',
        'deletedAt': FieldValue.serverTimestamp(),
        'deletedBy': currentUserId,
      }, SetOptions(merge: true));
    } else {
      await messageRef.set(<String, dynamic>{
        'deletedFor': FieldValue.arrayUnion([currentUserId]),
      }, SetOptions(merge: true));
    }

    print('[OnlineChatService] Message deleted');
  }

  // ── Report to Quarantine ──────────────────────────────────────────────
  Future<FeedbackUploadStatus> reportMessageToQuarantine({
    required String sender,
    required String message,
    required String source,
    String? messageDocPath,
  }) async {
    if (currentUserId.isEmpty) throw Exception('No logged-in user found');
    final reportedAtClientMs = DateTime.now().millisecondsSinceEpoch;

    final normalizedMessageDocPath = messageDocPath?.trim() ?? '';
    final quarantineDocId = normalizedMessageDocPath.isNotEmpty
        ? 'online_${normalizedMessageDocPath.replaceAll('/', '_')}'
        : 'manual_${DateTime.now().millisecondsSinceEpoch}_${sender.hashCode}';

    await _quarantineCollection(currentUserId).doc(quarantineDocId).set({
      'sender': sender,
      'message': message,
      'source': source,
      'messageDocPath':
          normalizedMessageDocPath.isEmpty ? null : normalizedMessageDocPath,
      'restoreMode': normalizedMessageDocPath.isNotEmpty ? 'messageDoc' : null,
      'detectionDecision': source == 'false_negative_online'
          ? DetectionDecision.manualReview
          : DetectionDecision.quarantineHighRisk,
      'detectionReasons': <String>[
        source == 'false_negative_online'
            ? 'User reported this message as smishing/spam.'
            : 'User confirmed this flagged message should stay quarantined.',
      ],
      'isSuspicious': true,
      'safetyStatus': SafetyStatus.malicious.value,
      'reportedAtClientMs': reportedAtClientMs,
      'reportedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (normalizedMessageDocPath.isNotEmpty) {
      await _firestore.doc(normalizedMessageDocPath).set({
        'isReported': true,
        'isSuspicious': true,
        'safetyStatus': SafetyStatus.malicious.value,
        'detectionDecision': source == 'false_negative_online'
            ? DetectionDecision.manualReview
            : DetectionDecision.quarantineHighRisk,
        'detectionReasons': <String>[
          source == 'false_negative_online'
              ? 'User reported this message as smishing/spam.'
              : 'User confirmed this flagged message should stay quarantined.',
        ],
      }, SetOptions(merge: true));
    }

    if (source == 'false_negative_sms' || source == 'false_negative_online') {
      return _feedbackDb.saveFalseNegative(
        message: message,
        source: source.replaceFirst('false_negative_', ''),
        sender: sender,
      );
    } else {
      return _feedbackDb.saveConfirmedSmishing(
        message: message,
        source: source,
        sender: sender,
      );
    }
  }

  // ── False Positive ────────────────────────────────────────────────────
  Future<FeedbackUploadStatus> removeFalsePositiveFromQuarantine(
    String docId,
  ) async {
    if (currentUserId.isEmpty) return FeedbackUploadStatus.disabled;

    FeedbackUploadStatus uploadStatus = FeedbackUploadStatus.disabled;

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

      final shouldRestoreMessageDoc = messageDocPath.isNotEmpty &&
          (restoreMode == 'messageDoc' || restoreMode.isEmpty);

      if (shouldRestoreMessageDoc) {
        try {
          await _firestore.doc(messageDocPath).set({
            'isReported': false,
            'isSuspicious': false,
            'safetyStatus': SafetyStatus.safe.value,
            'riskScore': FieldValue.delete(),
            'riskLevel': FieldValue.delete(),
            'detectionReasons': FieldValue.delete(),
            'detectionDecision': DetectionDecision.allowTrusted,
            'modelScore': FieldValue.delete(),
            'heuristicScore': FieldValue.delete(),
            'detectionSource': 'trusted_restore',
            'pipelineStage': 'trusted_restore',
            'primaryUrl': FieldValue.delete(),
            'primaryDomain': FieldValue.delete(),
            'extractedUrls': FieldValue.delete(),
            'needsRescan': false,
            'trustedByReceiverId': currentUserId,
            'trustedAt': FieldValue.serverTimestamp(),
            'screenedForReceiverId': currentUserId,
            'screenedForReceiverAt': FieldValue.serverTimestamp(),
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

      uploadStatus = await _feedbackDb.saveFalsePositive(
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

    await _quarantineCollection(currentUserId).doc(docId).delete();

    if (smsSenderForReconcile != null && smsSenderForReconcile.isNotEmpty) {
      await _smsStorageService.reconcileThreadMetadataForSender(
        smsSenderForReconcile,
      );
    }
    return uploadStatus;
  }

  Future<void> deleteQuarantineMessage(String docId) async {
    if (currentUserId.isEmpty || docId.isEmpty) return;

    String? smsSender;
    try {
      final doc = await _quarantineCollection(currentUserId).doc(docId).get();
      final data = doc.data();
      if ((data?['source']?.toString() ?? '').contains('sms')) {
        smsSender = data?['sender']?.toString();
      }
    } catch (_) {}

    await _quarantineCollection(currentUserId).doc(docId).delete();

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

    try {
      await _firestore.collection('chats').doc(chatId).update({
        'typing.$currentUserId': <String, dynamic>{
          'active': isTyping,
          'updatedAtClientMs': DateTime.now().millisecondsSinceEpoch,
        },
      });
    } catch (e) {
      // Ignore errors: if the chat doesn't exist yet, there's no need to update typing status.
    }
  }

  String? _extractInboundScreeningText(Map<String, dynamic> data) {
    final type = (data['type'] ?? data['messageType'] ?? 'text')
        .toString()
        .trim()
        .toLowerCase();
    switch (type) {
      case 'text':
        return data['text']?.toString().trim();
      default:
        return null;
    }
  }

  Future<void> saveIncomingMessageToQuarantine({
    required String sender,
    required String message,
    required String source,
    required String messageDocPath,
    required DetectionResultModel result,
    String? messageId,
  }) async {
    if (currentUserId.isEmpty) return;
    final reportedAtClientMs = DateTime.now().millisecondsSinceEpoch;

    final quarantineIdBase = messageId?.trim().isNotEmpty == true
        ? messageId!.trim()
        : messageDocPath;
    final quarantineId = 'online_${quarantineIdBase.replaceAll('/', '_')}';

    await _quarantineCollection(currentUserId).doc(quarantineId).set({
      'sender': sender,
      'message': message,
      'source': source,
      'messageDocPath': messageDocPath,
      'restoreMode': 'messageDoc',
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
      'reportedAtClientMs': reportedAtClientMs,
      'reportedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> upsertSmsQuarantineMirror(Map<String, dynamic> entry) async {
    if (currentUserId.isEmpty) return;

    final quarantineId = buildSmsQuarantineMirrorId(
      entry['id']?.toString() ?? '',
    );
    if (quarantineId.isEmpty) return;

    await _quarantineCollection(currentUserId).doc(quarantineId).set({
      'sender': entry['sender']?.toString() ?? 'Unknown',
      'message': entry['message']?.toString() ?? '',
      'source': entry['source']?.toString() ?? 'sms',
      'restoreMode': entry['restoreMode']?.toString() ?? 'smsThread',
      'threadId': entry['threadId']?.toString(),
      'simSlot': (entry['simSlot'] as num?)?.toInt() ?? 0,
      'providerId': (entry['providerId'] as num?)?.toInt(),
      'providerThreadId': entry['providerThreadId']?.toString(),
      'messageKey': entry['messageKey']?.toString(),
      'detectionDecision': entry['detectionDecision']?.toString(),
      'extractedUrls': entry['extractedUrls'] is Iterable
          ? List<String>.from(entry['extractedUrls'] as Iterable)
          : const <String>[],
      'primaryUrl': entry['primaryUrl']?.toString(),
      'primaryDomain': entry['primaryDomain']?.toString(),
      'needsRescan': entry['needsRescan'] == true,
      'safetyStatus':
          entry['safetyStatus']?.toString() ?? SafetyStatus.malicious.value,
      'time': entry['time']?.toString(),
      'timestamp': entry['timestamp']?.toString(),
      'timestampMs': (entry['timestampMs'] as num?)?.toInt(),
      'isSuspicious': entry['isSuspicious'] != false,
      'riskScore': (entry['riskScore'] as num?)?.toDouble() ?? 0.0,
      'riskLevel': entry['riskLevel']?.toString() ?? 'high',
      'detectionReasons': entry['detectionReasons'] is Iterable
          ? List<String>.from(entry['detectionReasons'] as Iterable)
          : const <String>[],
      'modelScore': (entry['modelScore'] as num?)?.toDouble(),
      'heuristicScore': (entry['heuristicScore'] as num?)?.toDouble() ?? 0.0,
      'detectionSource': entry['detectionSource']?.toString(),
      'pipelineStage': entry['pipelineStage']?.toString(),
      'quarantineReason': entry['quarantineReason']?.toString(),
      'reportedAtClientMs': (entry['timestampMs'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      'reportedAt': entry['reportedAt'] ?? FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> removeSmsQuarantineMirror(String quarantineId) async {
    if (currentUserId.isEmpty || quarantineId.trim().isEmpty) return;
    await _quarantineCollection(currentUserId)
        .doc(buildSmsQuarantineMirrorId(quarantineId))
        .delete();
  }

  Future<Map<String, dynamic>> ensureIncomingMessageScreenedAndLoad({
    required DocumentReference<Map<String, dynamic>> messageRef,
    required Map<String, dynamic> data,
  }) async {
    await ensureIncomingMessageScreened(messageRef: messageRef, data: data);
    try {
      final refreshed = await messageRef.get();
      return refreshed.data() ?? data;
    } catch (_) {
      return data;
    }
  }

  Future<void> ensureIncomingMessageScreened({
    required DocumentReference<Map<String, dynamic>> messageRef,
    required Map<String, dynamic> data,
  }) async {
    if (currentUserId.isEmpty) return;

    final senderId = data['senderId']?.toString().trim() ?? '';
    final receiverId = data['receiverId']?.toString().trim() ?? '';
    final type = (data['type'] ?? data['messageType'] ?? 'text')
        .toString()
        .trim()
        .toLowerCase();
    final docPath = messageRef.path;

    if (senderId.isEmpty ||
        receiverId.isEmpty ||
        senderId == currentUserId ||
        receiverId != currentUserId ||
        data['isDeleted'] == true ||
        type == 'deleted' ||
        type == 'call_summary') {
      return;
    }

    final screenedForReceiverId =
        data['screenedForReceiverId']?.toString().trim() ?? '';
    if (screenedForReceiverId == currentUserId) {
      return;
    }
    if (_incomingOnlineScreeningInFlight.contains(docPath)) {
      return;
    }

    final screeningText = _extractInboundScreeningText(data)?.trim() ?? '';
    if (screeningText.isEmpty) {
      try {
        await messageRef.set({
          'screenedForReceiverId': currentUserId,
          'screenedForReceiverAt': FieldValue.serverTimestamp(),
          'safetyStatus': SafetyStatus.safe.value,
        }, SetOptions(merge: true));
      } catch (_) {}
      return;
    }

    _incomingOnlineScreeningInFlight.add(docPath);
    try {
      await messageRef.set({
        'safetyStatus': SafetyStatus.scanning.value,
      }, SetOptions(merge: true));

      final timestampMs =
          _resolveMessageActivityTime(data).millisecondsSinceEpoch > 0
              ? _resolveMessageActivityTime(data).millisecondsSinceEpoch
              : DateTime.now().millisecondsSinceEpoch;
      final messageKey =
          data['clientMessageId']?.toString().trim().isNotEmpty == true
              ? data['clientMessageId'].toString().trim()
              : messageRef.id;

      final result = await _pipelineService.deepScan(
        ScreenedMessageModel(
          source: 'online_chat',
          sender: senderId,
          peer: currentUserId,
          body: screeningText,
          timestampMs: timestampMs,
          messageKey: messageKey,
          providerId: null,
          providerThreadId: null,
          simSlot: null,
          subscriptionId: null,
        ),
      );

      final flagged = result.shouldQuarantine;
      await messageRef.set({
        'isSuspicious': flagged,
        'safetyStatus':
            flagged ? SafetyStatus.malicious.value : SafetyStatus.safe.value,
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
        'screenedForReceiverId': currentUserId,
        'screenedForReceiverAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (flagged) {
        final senderLabel =
            data['senderName']?.toString().trim().isNotEmpty == true
                ? data['senderName'].toString().trim()
                : senderId;
        await saveIncomingMessageToQuarantine(
          sender: senderLabel,
          message: screeningText,
          source: 'online',
          messageDocPath: docPath,
          result: result,
          messageId: messageRef.id,
        );
      }
    } catch (error) {
      debugPrint(
          '[OnlineChatService] inbound screening failed for $docPath: $error');
    } finally {
      _incomingOnlineScreeningInFlight.remove(docPath);
    }
  }

  Stream<bool> getIsTyping({required String otherUserId}) {
    final chatId = getChatId(otherUserId);
    return _firestore.collection('chats').doc(chatId).snapshots().map((doc) {
      if (!doc.exists) return false;
      final data = doc.data();
      final typingRaw = data?['typing'];
      final typing = typingRaw is Map ? typingRaw : null;
      final otherTyping = typing?[otherUserId];
      if (otherTyping is bool) {
        return otherTyping;
      }
      if (otherTyping is! Map) {
        return false;
      }

      final active = otherTyping['active'] == true;
      if (!active) return false;

      final updatedAtClientMs =
          (otherTyping['updatedAtClientMs'] as num?)?.toInt() ?? 0;
      if (updatedAtClientMs <= 0) {
        return false;
      }

      final age = DateTime.now().millisecondsSinceEpoch - updatedAtClientMs;
      return age >= 0 && age <= typingIndicatorTimeout.inMilliseconds;
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
    final presenceMode = normalizePresenceMode(raw['presenceMode']?.toString());
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
        .snapshots();
  }
}
