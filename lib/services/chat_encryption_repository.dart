import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/conversation_preview_model.dart';
import '../models/decrypted_conversation_message.dart';
import '../models/detection_result_model.dart';
import '../models/screened_message_model.dart';
import '../models/safety_status.dart';
import 'feedback_database_service.dart';
import 'local_message_cache_service.dart';
import 'smishing_detection_pipeline_service.dart';
import 'security_service.dart';

class ChatEncryptionRepository {
  ChatEncryptionRepository._internal();

  static final ChatEncryptionRepository _instance =
      ChatEncryptionRepository._internal();
  factory ChatEncryptionRepository() => _instance;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final LocalMessageCacheService _cacheService = LocalMessageCacheService();
  final Uuid _uuid = const Uuid();

  final Map<String, String> _memoryPlaintextCache = <String, String>{};
  final Map<String, StreamController<List<DecryptedConversationMessage>>>
      _conversationControllers =
      <String, StreamController<List<DecryptedConversationMessage>>>{};
  final Map<String, StreamController<ConversationPreviewModel?>>
      _previewControllers =
      <String, StreamController<ConversationPreviewModel?>>{};
  final Map<String, Future<void>> _conversationSyncFutures =
      <String, Future<void>>{};
  final Map<String, String> _latestPreviewMessageIds = <String, String>{};
  final Map<String, String> _lastConversationEmitSignatures =
      <String, String>{};
  final Map<String, String?> _lastPreviewEmitSignatures = <String, String?>{};
  final SmishingDetectionPipelineService _smishingPipeline =
      SmishingDetectionPipelineService();
  final FeedbackDatabaseService _feedbackDb = FeedbackDatabaseService();
  final Map<String, bool> _detectionCache = <String, bool>{};
  final Set<String> _quarantineEntryCache = <String>{};
  final Map<String, Future<void>> _conversationPrewarmFutures =
      <String, Future<void>>{};
  final SecurityService _securityService = SecurityService();

  // Allows the background Isolate to maintain context without needing Auth state resolution
  String? _isolateUid;
  String get currentUserId => _isolateUid ?? _auth.currentUser?.uid ?? '';

  Future<void> initialize() async {}

  Future<void> ensureReady() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    await initialize();
  }

  String conversationIdFor(String otherUserId) {
    return _conversationId(currentUserId, otherUserId);
  }

  Stream<List<DecryptedConversationMessage>> watchConversation({
    required String otherUserId,
  }) {
    final conversationId = conversationIdFor(otherUserId);
    final controller = _conversationControllers.putIfAbsent(
      conversationId,
      () => StreamController<List<DecryptedConversationMessage>>.broadcast(),
    );
    return controller.stream;
  }

  Stream<ConversationPreviewModel?> watchConversationPreview({
    required String conversationId,
  }) {
    final controller = _previewControllers.putIfAbsent(
      conversationId,
      () => StreamController<ConversationPreviewModel?>.broadcast(),
    );
    return controller.stream;
  }

  Future<void> primeConversation({
    required String otherUserId,
  }) async {
    final conversationId = conversationIdFor(otherUserId);
    _conversationControllers.putIfAbsent(
      conversationId,
      () => StreamController<List<DecryptedConversationMessage>>.broadcast(),
    );
    // Clear the dedup signature so the next emit always delivers cached messages
    // to the new StreamBuilder subscriber (e.g. after back + re-open).
    _lastConversationEmitSignatures.remove(conversationId);
    await _emitConversationFromCache(conversationId);
  }

  Future<void> primeConversationPreview({
    required String conversationId,
  }) async {
    _previewControllers.putIfAbsent(
      conversationId,
      () => StreamController<ConversationPreviewModel?>.broadcast(),
    );
    await _emitPreviewFromCache(conversationId);
  }

  Future<void> syncConversationSnapshot({
    required String otherUserId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    List<DocumentChange<Map<String, dynamic>>>? docChanges,
  }) async {
    final conversationId = conversationIdFor(otherUserId);
    final existing = _conversationSyncFutures[conversationId];
    if (existing != null) {
      await existing;
    }

    final future = _syncConversationSnapshotInternal(
      conversationId: conversationId,
      otherUserId: otherUserId,
      docs: docs,
      docChanges: docChanges,
    );
    _conversationSyncFutures[conversationId] = future;
    try {
      await future;
    } finally {
      if (identical(_conversationSyncFutures[conversationId], future)) {
        _conversationSyncFutures.remove(conversationId);
      }
    }
  }

  Future<void> refreshConversationPreview({
    required String conversationId,
    required Map<String, dynamic> chatData,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;

    final previewType = chatData['lastMessageType']?.toString() ?? 'text';
    final remoteLastMessage = chatData['lastMessage']?.toString() ?? '';
    final lastMessageId = chatData['lastMessageId']?.toString() ??
        chatData['lastMessageClientMessageId']?.toString();
    final cachedPreview = await _cacheService.readConversationPreview(
      userId: uid,
      conversationId: conversationId,
    );
    if (cachedPreview != null) {
      final cachedLastMessageId =
          cachedPreview['last_message_id']?.toString().trim() ?? '';
      final expectedLastMessageId = lastMessageId?.trim() ?? '';
      if (expectedLastMessageId.isEmpty ||
          cachedLastMessageId.isEmpty ||
          cachedLastMessageId == expectedLastMessageId) {
        _previewControllers[conversationId]?.add(
          ConversationPreviewModel.fromCacheRow(cachedPreview),
        );
      }
    }

    if (previewType == 'image' ||
        previewType == 'gif' ||
        previewType == 'file') {
      final label = _safePreviewLabel(
        messageType: previewType,
        fallback: remoteLastMessage,
      );
      await _cacheService.saveConversationPreview(
        userId: uid,
        conversationId: conversationId,
        previewText: label,
        previewType: previewType,
        lastMessageId: lastMessageId,
        decryptionStatus: 'success',
      );
      await _emitPreviewFromCache(conversationId);
      return;
    }

    final cacheKey = chatData['lastMessageCacheKey']?.toString().trim() ?? '';
    if (cacheKey.isNotEmpty) {
      final cachedText = await getCachedPlaintext(cacheKey);
      if (cachedText != null && cachedText.trim().isNotEmpty) {
        await _cacheService.saveConversationPreview(
          userId: uid,
          conversationId: conversationId,
          previewText: cachedText,
          previewType: 'text',
          lastMessageId: lastMessageId,
          decryptionStatus: 'success',
        );
        await _emitPreviewFromCache(conversationId);
        return;
      }
    }

    final projection = await _cacheService.readMessageProjectionByIds(
      userId: uid,
      messageKey: cacheKey,
      messageId: lastMessageId,
      clientMessageId: lastMessageId,
    );
    if (projection != null) {
      final preview = projection['preview_text']?.toString().trim() ?? '';
      if (preview.isNotEmpty) {
        await _cacheService.saveConversationPreview(
          userId: uid,
          conversationId: conversationId,
          previewText: preview,
          previewType: projection['message_type']?.toString() ?? previewType,
          lastMessageId: lastMessageId ??
              projection['client_message_id']?.toString() ??
              projection['message_id']?.toString(),
          decryptionStatus:
              projection['decryption_status']?.toString() ?? 'success',
        );
        await _emitPreviewFromCache(conversationId);
        return;
      }
    }

    final encryptedText = chatData['lastMessageE2ee'] == true &&
        chatData['lastMessageType']?.toString() == 'encrypted_text' &&
        (chatData['lastMessageCipherText']?.toString().isNotEmpty ?? false);
    if (!encryptedText) {
      final fallback = remoteLastMessage.isNotEmpty
          ? remoteLastMessage
          : 'Tap to start chatting';
      await _cacheService.saveConversationPreview(
        userId: uid,
        conversationId: conversationId,
        previewText: fallback,
        previewType: previewType,
        lastMessageId: lastMessageId,
        decryptionStatus: 'success',
      );
      await _emitPreviewFromCache(conversationId);
      return;
    }

    final previewData = <String, dynamic>{
      'type': 'text',
      'e2ee': true,
      'e2eeAlgorithm':
          chatData['lastMessageAlgorithm']?.toString() ?? 'rsa-aes-cbc-v1',
      'cipherText': chatData['lastMessageCipherText'],
      'encrypted_aes_key': chatData['lastMessageEncryptedAesKey'],
      'iv': chatData['lastMessageIv'],
      'e2eeCacheKey': chatData['lastMessageCacheKey'],
      'senderId': chatData['lastMessageSenderId'],
      'receiverId':
          chatData['lastMessageReceiverId']?.toString().isNotEmpty == true
              ? chatData['lastMessageReceiverId']
              : _deriveOtherParticipant(
                  chatData['participants'],
                  chatData['lastMessageSenderId']?.toString() ?? '',
                ),
      'senderPublicKey': chatData['lastMessageSenderPublicKey'],
      'receiverPublicKey': chatData['lastMessageReceiverPublicKey'],
      'messageId': lastMessageId,
      'clientMessageId': lastMessageId,
      'timestamp': chatData['lastMessageAt'] ?? chatData['updatedAt'],
      'isSuspicious': chatData['lastMessageIsSuspicious'] == true,
    };

    final mapped = await mapRemoteMessage(
      conversationId: conversationId,
      messageId: lastMessageId ?? cacheKey,
      data: previewData,
    );
    await _cacheService.saveConversationPreview(
      userId: uid,
      conversationId: conversationId,
      previewText: mapped.previewText,
      previewType: mapped.messageType,
      lastMessageId:
          lastMessageId ?? mapped.clientMessageId ?? mapped.messageId,
      decryptionStatus: mapped.decryptionStatus.value,
    );
    await _emitPreviewFromCache(conversationId);
  }

  Future<String?> getCachedPlaintext(String cacheKey) async {
    final inMemory = _memoryPlaintextCache[cacheKey];
    if (inMemory != null) {
      return inMemory;
    }
    final uid = currentUserId;
    if (uid.isEmpty) return null;
    final persisted = await _cacheService.readDecryptedMessage(
      userId: uid,
      messageKey: cacheKey,
    );
    if (persisted != null && persisted.isNotEmpty) {
      _memoryPlaintextCache[cacheKey] = persisted;
    }
    return persisted;
  }

  String? peekCachedPlaintext(String cacheKey) {
    final trimmed = cacheKey.trim();
    if (trimmed.isEmpty) return null;
    return _memoryPlaintextCache[trimmed];
  }

  Future<void> seedPlaintextCache({
    required String cacheKey,
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String senderId,
    required String receiverId,
    required String plaintext,
    required String messageType,
  }) async {
    await cachePlaintext(
      cacheKey: cacheKey,
      conversationId: conversationId,
      messageId: messageId,
      clientMessageId: clientMessageId,
      senderId: senderId,
      receiverId: receiverId,
      plaintext: plaintext,
      messageType: messageType,
    );
  }

  Future<void> cachePlaintext({
    required String cacheKey,
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String senderId,
    required String receiverId,
    required String plaintext,
    required String messageType,
    bool updateConversationPreview = true,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty || cacheKey.trim().isEmpty || plaintext.trim().isEmpty) {
      return;
    }
    _memoryPlaintextCache[cacheKey] = plaintext;
    await _cacheService.saveDecryptedMessage(
      userId: uid,
      messageKey: cacheKey,
      conversationId: conversationId,
      messageId: messageId,
      clientMessageId: clientMessageId,
      senderId: senderId,
      receiverId: receiverId,
      messageType: messageType,
      plaintext: plaintext,
    );
    await _emitConversationFromCache(conversationId);
    if (updateConversationPreview) {
      await _cacheService.saveConversationPreview(
        userId: uid,
        conversationId: conversationId,
        previewText: plaintext,
        previewType: messageType,
        lastMessageId: clientMessageId ?? messageId,
      );
      await _emitPreviewFromCache(conversationId);
    }
  }

  Future<void> finalizeOutgoingTextProjection({
    required String conversationId,
    required String messageId,
    required String? clientMessageId,
    required String cacheKey,
    required String senderId,
    required String receiverId,
    required String plaintext,
    required String messageType,
    int? timestampMs,
    String? algorithm,
  }) async {
    final uid = currentUserId;
    final trimmedCacheKey = cacheKey.trim();
    final trimmedMessageId = messageId.trim();
    final trimmedPlaintext = plaintext.trim();
    if (uid.isEmpty ||
        conversationId.trim().isEmpty ||
        trimmedCacheKey.isEmpty ||
        trimmedMessageId.isEmpty ||
        trimmedPlaintext.isEmpty) {
      return;
    }

    final resolvedClientMessageId = clientMessageId?.trim().isNotEmpty == true
        ? clientMessageId!.trim()
        : trimmedMessageId;
    final resolvedTimestampMs = timestampMs != null && timestampMs > 0
        ? timestampMs
        : DateTime.now().millisecondsSinceEpoch;

    final projection = DecryptedConversationMessage(
      conversationId: conversationId,
      messageKey: trimmedCacheKey,
      messageId: trimmedMessageId,
      clientMessageId: resolvedClientMessageId,
      senderId: senderId.trim(),
      receiverId: receiverId.trim(),
      messageType: messageType.trim().isNotEmpty ? messageType.trim() : 'text',
      algorithm: algorithm,
      cipherTextPresent: true,
      decryptedText: trimmedPlaintext,
      previewText: trimmedPlaintext,
      decryptionStatus: ConversationDecryptionStatus.success,
      failureReason: null, // This marks it as "sent"
      timestamp: DateTime.fromMillisecondsSinceEpoch(resolvedTimestampMs),
      isOutgoing: senderId.trim() == uid,
      isDeleted: false,
      isSuspicious: false,
    );
    await _persistProjection(projection);
  }

  Future<String> createPendingOutgoingMessageProjection({
    required String conversationId,
    required String receiverId,
    required String plaintext,
    required String messageType,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No user');
    }
    final clientMessageId = _uuid.v4();
    final now = DateTime.now();
    final projection = DecryptedConversationMessage(
      conversationId: conversationId,
      messageKey: clientMessageId, // Use clientMessageId as a temporary key
      messageId: null, // Not yet on server
      clientMessageId: clientMessageId,
      senderId: uid,
      receiverId: receiverId,
      messageType: messageType,
      algorithm: null,
      cipherTextPresent: false,
      decryptedText: plaintext,
      previewText: plaintext,
      decryptionStatus: ConversationDecryptionStatus.success,
      failureReason: 'sending...', // Use this field to indicate status
      timestamp: now,
      isOutgoing: true,
      isDeleted: false,
      isSuspicious: false,
    );
    await _persistProjection(projection);
    await _emitConversationFromCache(conversationId);
    return clientMessageId;
  }

  Future<void> failOutgoingMessageProjection({
    required String clientMessageId,
    required String conversationId,
    required String reason,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;

    // Just update the status in the DB.
    // This assumes your cache service can update a single field.
    await _cacheService.updateMessageProjectionStatus(
      userId: uid,
      clientMessageId: clientMessageId,
      updates: {
        'failure_reason': reason,
      },
    );
    await _emitConversationFromCache(conversationId);
  }

  Future<void> cacheOutgoingMediaBytes({
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String? cacheKey,
    required String senderId,
    required String receiverId,
    required Uint8List bytes,
    required String messageType,
    String? fileName,
  }) async {
    await _cacheMediaBytes(
      conversationId: conversationId,
      messageId: messageId,
      clientMessageId: clientMessageId,
      cacheKey: cacheKey,
      senderId: senderId,
      receiverId: receiverId,
      bytes: bytes,
      messageType: messageType,
      fileName: fileName,
    );
  }

  Future<void> cacheIncomingMediaBytes({
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String? cacheKey,
    required String senderId,
    required String receiverId,
    required Uint8List bytes,
    required String messageType,
    String? fileName,
  }) async {
    await _cacheMediaBytes(
      conversationId: conversationId,
      messageId: messageId,
      clientMessageId: clientMessageId,
      cacheKey: cacheKey,
      senderId: senderId,
      receiverId: receiverId,
      bytes: bytes,
      messageType: messageType,
      fileName: fileName,
    );
  }

  Future<Uint8List?> getCachedMediaBytes({
    String? cacheKey,
    String? messageId,
    String? clientMessageId,
    String? fileName,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) return null;
    return _cacheService.readDecryptedMediaBytes(
      userId: uid,
      messageKey: _resolveMediaCacheIdentity(
        cacheKey: cacheKey,
        clientMessageId: clientMessageId,
        messageId: messageId,
      ),
      messageId: messageId,
      clientMessageId: clientMessageId,
      fileName: fileName,
    );
  }

  Future<DecryptedConversationMessage> mapRemoteMessage({
    required String conversationId,
    required String messageId,
    required Map<String, dynamic> data,
    String? otherUserId,
    bool ensureInitialized = true,
  }) async {
    if (ensureInitialized) {
      await ensureReady();
    }
    final uid = currentUserId;
    final normalized = _normalizeRemoteMessage(
      data,
      messageId: messageId,
      otherUserId: otherUserId,
    );

    final senderId = normalized['senderId']?.toString() ?? '';
    final receiverId = normalized['receiverId']?.toString() ?? '';
    final clientMessageId = normalized['clientMessageId']?.toString();
    final messageType = normalized['type']?.toString() ?? 'text';
    final algorithm = normalized['e2eeAlgorithm']?.toString();
    final isDeleted =
        normalized['isDeleted'] == true || messageType == 'deleted';
    final isSuspicious = normalized['isSuspicious'] == true;
    final remoteRiskScore = _extractRemoteRiskScore(normalized);
    final timestamp = _resolveMessageTimestamp(normalized);
    final cacheKey = buildMessageCacheKey(normalized);

    final existing = await _cacheService.readMessageProjectionByIds(
      userId: uid,
      messageKey: cacheKey,
      messageId: messageId,
      clientMessageId: clientMessageId,
    );
    if (existing != null) {
      final projection = DecryptedConversationMessage.fromCacheRow(
        existing,
        currentUserId: uid,
      );
      final sameCacheKey = projection.messageKey == cacheKey;
      final sameClientMessageId = (projection.clientMessageId ?? '').trim() ==
              (clientMessageId ?? '').trim() &&
          (clientMessageId ?? '').trim().isNotEmpty;
      final lastUpdatedAt = DateTime.fromMillisecondsSinceEpoch(
        (existing['updated_at'] as num?)?.toInt() ?? 0,
      );
      const retryCooldown = Duration(seconds: 30);
      final recentFailure =
          projection.decryptionStatus == ConversationDecryptionStatus.failed &&
              DateTime.now().difference(lastUpdatedAt) < retryCooldown;
      if ((sameCacheKey || sameClientMessageId) &&
          (projection.decryptionStatus ==
                  ConversationDecryptionStatus.success ||
              recentFailure)) {
        final needsSafetyVerdict = !projection.isOutgoing &&
            !projection.isDeleted &&
            projection.messageType == 'text' &&
            !projection.isSuspicious &&
            projection.safetyStatus == SafetyStatus.safe &&
            projection.riskScore == null;
        if (!needsSafetyVerdict) {
          return projection;
        }
      }
    }

    if (isDeleted) {
      final projection = DecryptedConversationMessage(
        conversationId: conversationId,
        messageKey: cacheKey,
        messageId: messageId,
        clientMessageId: clientMessageId,
        senderId: senderId,
        receiverId: receiverId,
        messageType: 'deleted',
        algorithm: algorithm,
        cipherTextPresent:
            normalized['cipherText']?.toString().trim().isNotEmpty == true,
        decryptedText: '',
        previewText: 'Message deleted',
        decryptionStatus: ConversationDecryptionStatus.success,
        failureReason: null,
        timestamp: timestamp,
        isOutgoing: senderId == uid,
        isDeleted: true,
        isSuspicious: false,
        safetyStatus: SafetyStatus.safe,
        riskScore: null,
      );
      await _persistProjection(projection);
      return projection;
    }

    if (messageType != 'text' || normalized['e2ee'] != true) {
      final preview = _safePreviewLabel(
        messageType: messageType,
        fallback: normalized['text']?.toString() ?? '',
        fileName: normalized['fileName']?.toString(),
      );
      final projection = DecryptedConversationMessage(
        conversationId: conversationId,
        messageKey: cacheKey,
        messageId: messageId,
        clientMessageId: clientMessageId,
        senderId: senderId,
        receiverId: receiverId,
        messageType: messageType,
        algorithm: algorithm,
        cipherTextPresent:
            normalized['cipherText']?.toString().trim().isNotEmpty == true,
        decryptedText: normalized['text']?.toString(),
        previewText: preview,
        decryptionStatus: ConversationDecryptionStatus.success,
        failureReason: null,
        timestamp: timestamp,
        isOutgoing: senderId == uid,
        isDeleted: false,
        isSuspicious: isSuspicious,
        safetyStatus: isSuspicious ? SafetyStatus.malicious : SafetyStatus.safe,
        riskScore: remoteRiskScore,
      );
      final scannedProjection = await _applyIncomingSafetyPipeline(projection);
      await _persistProjection(scannedProjection);
      return scannedProjection;
    }

    final cachedPlaintext = await getCachedPlaintext(cacheKey);
    if (cachedPlaintext != null && cachedPlaintext.trim().isNotEmpty) {
      final projection = DecryptedConversationMessage(
        conversationId: conversationId,
        messageKey: cacheKey,
        messageId: messageId,
        clientMessageId: clientMessageId,
        senderId: senderId,
        receiverId: receiverId,
        messageType: messageType,
        algorithm: algorithm,
        cipherTextPresent: true,
        decryptedText: cachedPlaintext,
        previewText: cachedPlaintext,
        decryptionStatus: ConversationDecryptionStatus.success,
        failureReason: null,
        timestamp: timestamp,
        isOutgoing: senderId == uid,
        isDeleted: false,
        isSuspicious: isSuspicious,
        safetyStatus: isSuspicious ? SafetyStatus.malicious : SafetyStatus.safe,
        riskScore: remoteRiskScore,
      );
      final scannedProjection = await _applyIncomingSafetyPipeline(projection);
      await _persistProjection(scannedProjection);
      return scannedProjection;
    }

    String? decryptedText;
    try {
      decryptedText = await _securityService.decryptMessage(normalized);
    } catch (e) {
      debugPrint('[ChatEncryptRepo] Decryption failed: $e');
    }

    if (decryptedText != null && decryptedText.trim().isNotEmpty) {
      final projection = DecryptedConversationMessage(
        conversationId: conversationId,
        messageKey: cacheKey,
        messageId: messageId,
        clientMessageId: clientMessageId,
        senderId: senderId,
        receiverId: receiverId,
        messageType: messageType,
        algorithm: algorithm,
        cipherTextPresent: true,
        decryptedText: decryptedText,
        previewText: decryptedText,
        decryptionStatus: ConversationDecryptionStatus.success,
        failureReason: null,
        timestamp: timestamp,
        isOutgoing: senderId == uid,
        isDeleted: false,
        isSuspicious: isSuspicious,
        safetyStatus: isSuspicious ? SafetyStatus.malicious : SafetyStatus.safe,
        riskScore: remoteRiskScore,
      );
      final scannedProjection = await _applyIncomingSafetyPipeline(projection);
      await _persistProjection(scannedProjection);
      return scannedProjection;
    }

    final lowerAlgo = algorithm?.toLowerCase() ?? '';
    final indicator = lowerAlgo.contains('rsa') ? 'RSA' : 'E2EE';

    // Outgoing messages are encrypted for the receiver's key, so local RSA
    // decryption is expected to fail. Don't show a scary "Unable to decrypt"
    // error bubble for the sender.
    if (senderId == uid) {
      final fallbackText = '$indicator encrypted message';
      final projection = DecryptedConversationMessage(
        conversationId: conversationId,
        messageKey: cacheKey,
        messageId: messageId,
        clientMessageId: clientMessageId,
        senderId: senderId,
        receiverId: receiverId,
        messageType: messageType,
        algorithm: algorithm,
        cipherTextPresent: true,
        decryptedText: fallbackText,
        previewText: fallbackText,
        decryptionStatus: ConversationDecryptionStatus.success,
        failureReason: null,
        timestamp: timestamp,
        isOutgoing: true,
        isDeleted: false,
        isSuspicious: isSuspicious,
        safetyStatus: isSuspicious ? SafetyStatus.malicious : SafetyStatus.safe,
        riskScore: remoteRiskScore,
      );
      await _persistProjection(projection);
      return projection;
    }

    final projection = DecryptedConversationMessage(
      conversationId: conversationId,
      messageKey: cacheKey,
      messageId: messageId,
      clientMessageId: clientMessageId,
      senderId: senderId,
      receiverId: receiverId,
      messageType: messageType,
      algorithm: algorithm,
      cipherTextPresent: true,
      decryptedText: null,
      previewText: '$indicator encrypted message',
      decryptionStatus: ConversationDecryptionStatus.failed,
      failureReason: 'Unable to decrypt message',
      timestamp: timestamp,
      isOutgoing: senderId == uid,
      isDeleted: false,
      isSuspicious: senderId == uid
          ? isSuspicious
          : false, // Un-decryptable incoming is not marked suspicious
      safetyStatus: senderId == uid
          ? (isSuspicious ? SafetyStatus.malicious : SafetyStatus.safe)
          : SafetyStatus.safe,
      riskScore: senderId == uid ? remoteRiskScore : null,
    );
    await _persistProjection(projection);
    return projection;
  }

  Future<DecryptedConversationMessage> _applyIncomingSafetyPipeline(
    DecryptedConversationMessage projection,
  ) async {
    if (projection.isOutgoing ||
        projection.isDeleted ||
        projection.messageType != 'text') {
      return projection;
    }

    // If this message was already flagged remotely (persisted to Firestore),
    // don’t spend cycles re-scanning it just to re-derive the same label.
    if (projection.isSuspicious && projection.riskScore != null) {
      return projection.copyWith(safetyStatus: SafetyStatus.malicious);
    }

    final plaintext = projection.decryptedText?.trim().isNotEmpty == true
        ? projection.decryptedText!.trim()
        : projection.previewText.trim();
    if (plaintext.isEmpty) {
      return projection;
    }

    final detectionKey = projection.clientMessageId?.trim().isNotEmpty == true
        ? projection.clientMessageId!.trim()
        : projection.messageId ?? projection.messageKey;
    if (_detectionCache.containsKey(detectionKey)) {
      final suspicious = _detectionCache[detectionKey]!;
      return projection.copyWith(
        isSuspicious: suspicious,
        safetyStatus: suspicious ? SafetyStatus.malicious : SafetyStatus.safe,
      );
    }

    final screenedMessage = ScreenedMessageModel(
      source: 'online_chat',
      sender: projection.senderId,
      peer: projection.senderId,
      body: plaintext,
      timestampMs: projection.timestamp.millisecondsSinceEpoch,
      messageKey: projection.messageKey,
      providerId: null,
      providerThreadId: null,
      simSlot: null,
      subscriptionId: null,
    );

    try {
      final verdict = await _smishingPipeline.quickScan(screenedMessage);
      if (verdict.result != null) {
        _detectionCache[detectionKey] = verdict.result!.isSuspicious;
        final updated =
            _projectionWithDetectionResult(projection, verdict.result!);
        unawaited(_persistQuarantineVaultEntryIfNeeded(
          projection: updated,
          result: verdict.result!,
          plaintext: plaintext,
        ));
        unawaited(_persistDetectionToRemoteIfNeeded(
          projection: updated,
          result: verdict.result!,
        ));
        return updated;
      }

      final scanningProjection = projection.copyWith(
        isSuspicious: false,
        safetyStatus: SafetyStatus.scanning,
        riskScore: null,
      );
      _smishingPipeline.enqueue(
        message: screenedMessage,
        priority: SmishingQueuePriority.high,
        onResult: (DetectionResultModel result) async {
          _detectionCache[detectionKey] = result.isSuspicious;
          final updatedProjection =
              _projectionWithDetectionResult(scanningProjection, result);
          await _persistProjection(updatedProjection);
          await _emitConversationFromCache(projection.conversationId);
          unawaited(_persistQuarantineVaultEntryIfNeeded(
            projection: updatedProjection,
            result: result,
            plaintext: plaintext,
          ));
          unawaited(_persistDetectionToRemoteIfNeeded(
            projection: updatedProjection,
            result: result,
          ));
        },
      );
      return scanningProjection;
    } catch (e) {
      debugPrint(
        '[ChatEncryptRepo] Detection failed for '
        '${projection.messageId ?? projection.messageKey}: $e',
      );
      return projection;
    }
  }

  DecryptedConversationMessage _projectionWithDetectionResult(
    DecryptedConversationMessage projection,
    DetectionResultModel result,
  ) {
    return projection.copyWith(
      isSuspicious: result.isSuspicious,
      safetyStatus:
          result.isSuspicious ? SafetyStatus.malicious : SafetyStatus.safe,
      riskScore: result.riskScore,
    );
  }

  double? _extractRemoteRiskScore(Map<String, dynamic> data) {
    final direct = data['riskScore'];
    final parsed = _coerceDouble(direct);
    if (parsed != null) {
      return parsed;
    }

    final smishing = data['smishing'];
    if (smishing is Map) {
      return _coerceDouble(smishing['riskScore'] ?? smishing['modelScore']);
    }
    return null;
  }

  double? _coerceDouble(dynamic raw) {
    if (raw == null) return null;
    if (raw is double) return raw;
    if (raw is int) return raw.toDouble();
    if (raw is num) return raw.toDouble();
    if (raw is String) {
      return double.tryParse(raw.trim());
    }
    return null;
  }

  Future<void> _persistDetectionToRemoteIfNeeded({
    required DecryptedConversationMessage projection,
    required DetectionResultModel result,
  }) async {
    if (projection.isOutgoing || projection.isDeleted) return;
    if (!result.isSuspicious && !result.shouldQuarantine) return;

    final conversationId = projection.conversationId.trim();
    if (conversationId.isEmpty) return;

    final docId = (projection.messageId ?? '').trim().isNotEmpty
        ? projection.messageId!.trim()
        : (projection.clientMessageId ?? '').trim();
    if (docId.isEmpty) return;

    try {
      final messageRef = FirebaseFirestore.instance
          .collection('chats')
          .doc(conversationId)
          .collection('messages')
          .doc(docId);

      await messageRef.set(<String, dynamic>{
        'isSuspicious': true,
        'riskScore': result.riskScore,
        'smishing': result.toSmsMetadataMap(),
        'smishingUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      final chatRef =
          FirebaseFirestore.instance.collection('chats').doc(conversationId);
      await FirebaseFirestore.instance.runTransaction((txn) async {
        final snap = await txn.get(chatRef);
        final data = snap.data() ?? const <String, dynamic>{};
        final lastId =
            data['lastMessageClientMessageId']?.toString().trim() ?? '';
        if (lastId == docId) {
          txn.set(
              chatRef,
              <String, dynamic>{
                'lastMessageIsSuspicious': true,
              },
              SetOptions(merge: true));
        }
      });
    } catch (e) {
      // Non-fatal: local labeling still works; this just makes it persist
      // across devices/re-logins.
      debugPrint('[ChatEncryptRepo] Remote smishing persist failed: $e');
    }
  }

  Future<void> _persistQuarantineVaultEntryIfNeeded({
    required DecryptedConversationMessage projection,
    required DetectionResultModel result,
    required String plaintext,
  }) async {
    if (projection.isOutgoing || projection.isDeleted) return;
    if (!result.isSuspicious) return;

    final uid = currentUserId;
    if (uid.isEmpty) return;

    final conversationId = projection.conversationId.trim();
    if (conversationId.isEmpty) return;

    final messageDocId = (projection.messageId ?? '').trim().isNotEmpty
        ? projection.messageId!.trim()
        : (projection.clientMessageId ?? '').trim();
    if (messageDocId.isEmpty) return;

    final entryId = 'online_${conversationId}_$messageDocId';
    final quarantineRef = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('quarantine')
        .doc(entryId);

    bool existed = _quarantineEntryCache.contains(entryId);
    if (!existed) {
      try {
        final snap = await quarantineRef.get();
        existed = snap.exists;
      } catch (_) {
        // If Firestore read fails (offline), still proceed with a best-effort write.
      }
    }

    final messageDocPath =
        'chats/$conversationId/messages/${projection.messageId?.trim().isNotEmpty == true ? projection.messageId!.trim() : messageDocId}';

    try {
      await quarantineRef.set(<String, dynamic>{
        'sender': projection.senderId,
        'message': plaintext,
        'source': 'online',
        'messageDocPath': messageDocPath,
        'restoreMode': 'messageDoc',
        'reportedAt': FieldValue.serverTimestamp(),
        'riskScore': result.riskScore,
        'riskLevel': result.riskLevel,
        'detectionReasons': result.explanations,
        'detectionSource': result.detectionSource,
        'pipelineStage': result.pipelineStage,
        'detectionDecision': result.decision,
        'smishing': result.toSmsMetadataMap(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('[ChatEncryptRepo] Quarantine vault persist failed: $e');
      return;
    }

    _quarantineEntryCache.add(entryId);

    // Mark the underlying message doc as reported if we can. This is optional
    // (rules may deny recipients from mutating chat messages).
    try {
      await FirebaseFirestore.instance.doc(messageDocPath).set(
        <String, dynamic>{'isReported': true},
        SetOptions(merge: true),
      );
    } catch (_) {}

    // Counter / contribution hub: only increment once per message.
    if (!existed) {
      try {
        await _feedbackDb.saveConfirmedSmishing(
          message: plaintext,
          source: 'online',
          sender: projection.senderId,
        );
      } catch (_) {}
    }
  }

  String buildMessageCacheKey(Map<String, dynamic> data) {
    final explicit = data['e2eeCacheKey']?.toString().trim() ?? '';
    if (explicit.isNotEmpty) {
      return explicit;
    }
    final senderId = data['senderId']?.toString().trim() ?? '';
    final receiverId = data['receiverId']?.toString().trim() ?? '';
    final cipherText = data['cipherText']?.toString().trim() ?? '';
    if (cipherText.isNotEmpty) {
      final shortCipher = cipherText.substring(0, min(cipherText.length, 48));
      return '$senderId|$receiverId|$shortCipher';
    }
    return '${data['messageId'] ?? data['clientMessageId'] ?? _uuid.v4()}';
  }

  Future<void> prewarmConversation(String peerUserId) async {
    final trimmedPeerUserId = peerUserId.trim();
    if (trimmedPeerUserId.isEmpty) {
      return;
    }

    final existing = _conversationPrewarmFutures[trimmedPeerUserId];
    if (existing != null) {
      await existing;
      return;
    }

    final future = () async {
      try {
        await ensureReady();
      } catch (e) {
        debugPrint('[ChatEncryptRepo] Prewarm failed (non-fatal): $e');
      }
    }();
    _conversationPrewarmFutures[trimmedPeerUserId] = future;
    try {
      await future;
    } finally {
      if (identical(
        _conversationPrewarmFutures[trimmedPeerUserId],
        future,
      )) {
        _conversationPrewarmFutures.remove(trimmedPeerUserId);
      }
    }
  }

  Future<void> _syncConversationSnapshotInternal({
    required String conversationId,
    required String otherUserId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    List<DocumentChange<Map<String, dynamic>>>? docChanges,
  }) async {
    await _emitConversationFromCache(conversationId);
    if (docs.isEmpty) {
      _latestPreviewMessageIds.remove(conversationId);
      await _emitPreviewFromCache(conversationId);
      return;
    }

    await ensureReady();
    await prewarmConversation(otherUserId);

    final orderedDocs =
        List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(docs);

    if (docChanges == null) {
      final newestDocs = orderedDocs.take(20).toList(growable: false);
      final olderDocs = orderedDocs.skip(20).toList(growable: false);

      final warmedNewest = await _processConversationDocs(
        conversationId: conversationId,
        otherUserId: otherUserId,
        docs: newestDocs,
      );
      if (warmedNewest) {
        await _emitConversationFromCache(conversationId);
      }

      await _syncLatestPreviewFromDoc(
        conversationId: conversationId,
        otherUserId: otherUserId,
        latestDoc: orderedDocs.first,
      );

      if (olderDocs.isNotEmpty) {
        await _hydrateOlderConversationHistory(
          conversationId: conversationId,
          otherUserId: otherUserId,
          docs: olderDocs,
        );
      }
      return;
    }

    final currentDocsById =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{
      for (final doc in orderedDocs) doc.id: doc,
    };
    final changedDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    for (final change in docChanges) {
      if (change.type == DocumentChangeType.removed) {
        continue;
      }
      final current = currentDocsById[change.doc.id];
      if (current != null) {
        changedDocs.add(current);
      }
    }

    final processedAny = await _processConversationDocs(
      conversationId: conversationId,
      otherUserId: otherUserId,
      docs: changedDocs,
    );
    if (processedAny) {
      await _emitConversationFromCache(conversationId);
    }

    final currentLatestIdentity = _messageIdentityFromDoc(orderedDocs.first);
    final shouldRefreshLatestPreview = currentLatestIdentity !=
            (_latestPreviewMessageIds[conversationId] ?? '') ||
        docChanges.any((change) => change.doc.id == orderedDocs.first.id) ||
        docChanges.any((change) => change.type == DocumentChangeType.removed);
    if (shouldRefreshLatestPreview) {
      await _syncLatestPreviewFromDoc(
        conversationId: conversationId,
        otherUserId: otherUserId,
        latestDoc: orderedDocs.first,
      );
    }
  }

  Future<void> _hydrateOlderConversationHistory({
    required String conversationId,
    required String otherUserId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  }) async {
    if (docs.isEmpty) return;

    for (var i = 0; i < docs.length; i += 20) {
      final batch = docs.skip(i).take(20).toList(growable: false);
      final processedAny = await _processConversationDocs(
        conversationId: conversationId,
        otherUserId: otherUserId,
        docs: batch,
      );
      if (processedAny) {
        await _emitConversationFromCache(conversationId);
      }
      // YIELD: Give the UI 15ms to render frames so scrolling stays buttery smooth
      await Future<void>.delayed(const Duration(milliseconds: 15));
    }

    await _emitConversationFromCache(conversationId);
  }

  Future<bool> _processConversationDocs({
    required String conversationId,
    required String otherUserId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  }) async {
    if (docs.isEmpty) {
      return false;
    }

    var processedAny = false;
    for (final doc in docs) {
      // YIELD: Prevent UI freezing during decryption work.
      await Future<void>.delayed(const Duration(milliseconds: 4));

      final rawData = Map<String, dynamic>.from(doc.data())
        ..putIfAbsent('messageId', () => doc.id);
      final normalized = _normalizeRemoteMessage(
        rawData,
        messageId: doc.id,
        otherUserId: otherUserId,
      );
      await mapRemoteMessage(
        conversationId: conversationId,
        messageId: doc.id,
        data: normalized,
        otherUserId: otherUserId,
        ensureInitialized: false,
      );
      processedAny = true;
    }
    return processedAny;
  }

  Future<void> _syncLatestPreviewFromDoc({
    required String conversationId,
    required String otherUserId,
    required QueryDocumentSnapshot<Map<String, dynamic>> latestDoc,
  }) async {
    final latestProjection = await mapRemoteMessage(
      conversationId: conversationId,
      messageId: latestDoc.id,
      data: Map<String, dynamic>.from(latestDoc.data())
        ..putIfAbsent('messageId', () => latestDoc.id),
      otherUserId: otherUserId,
      ensureInitialized: false,
    );
    final latestMessageIdentity = latestProjection.clientMessageId ??
        latestProjection.messageId ??
        latestDoc.id;
    _latestPreviewMessageIds[conversationId] = latestMessageIdentity;
    await _cacheService.saveConversationPreview(
      userId: currentUserId,
      conversationId: conversationId,
      previewText: latestProjection.previewText,
      previewType: latestProjection.messageType,
      lastMessageId: latestMessageIdentity,
      decryptionStatus: latestProjection.decryptionStatus.value,
    );
    await _emitPreviewFromCache(conversationId);
  }

  Future<void> _persistProjection(
      DecryptedConversationMessage projection) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;

    if (projection.decryptedText != null &&
        projection.decryptedText!.trim().isNotEmpty) {
      _memoryPlaintextCache[projection.messageKey] = projection.decryptedText!;
    }

    await _cacheService.upsertMessageProjection(
      userId: uid,
      messageKey: projection.messageKey,
      conversationId: projection.conversationId,
      messageId: projection.messageId,
      clientMessageId: projection.clientMessageId,
      senderId: projection.senderId,
      receiverId: projection.receiverId,
      messageType: projection.messageType,
      plaintext: projection.decryptedText,
      previewText: projection.previewText,
      decryptionStatus: projection.decryptionStatus.value,
      failureReason: projection.failureReason,
      algorithm: projection.algorithm,
      timestampMs: projection.timestamp.millisecondsSinceEpoch,
      cipherTextPresent: projection.cipherTextPresent,
      isDeleted: projection.isDeleted,
      isSuspicious: projection.isSuspicious,
      safetyStatus: projection.safetyStatus.value,
      riskScore: projection.riskScore,
    );
  }

  Future<void> _cacheMediaBytes({
    required String conversationId,
    required String? messageId,
    required String? clientMessageId,
    required String? cacheKey,
    required String senderId,
    required String receiverId,
    required Uint8List bytes,
    required String messageType,
    String? fileName,
  }) async {
    final uid = currentUserId;
    final messageKey = _resolveMediaCacheIdentity(
      cacheKey: cacheKey,
      clientMessageId: clientMessageId,
      messageId: messageId,
    );
    if (uid.isEmpty ||
        conversationId.trim().isEmpty ||
        messageKey.isEmpty ||
        bytes.isEmpty) {
      return;
    }

    await _cacheService.saveDecryptedMedia(
      userId: uid,
      messageKey: messageKey,
      conversationId: conversationId,
      messageId: messageId?.trim(),
      clientMessageId: clientMessageId?.trim(),
      senderId: senderId.trim(),
      receiverId: receiverId.trim(),
      messageType: messageType.trim().isNotEmpty ? messageType.trim() : 'file',
      fileName: fileName?.trim(),
      bytes: bytes,
    );
  }

  String _resolveMediaCacheIdentity({
    String? cacheKey,
    String? clientMessageId,
    String? messageId,
  }) {
    final trimmedCacheKey = cacheKey?.trim() ?? '';
    if (trimmedCacheKey.isNotEmpty) {
      return trimmedCacheKey;
    }
    final trimmedClientMessageId = clientMessageId?.trim() ?? '';
    if (trimmedClientMessageId.isNotEmpty) {
      return trimmedClientMessageId;
    }
    return messageId?.trim() ?? '';
  }

  Future<void> _emitConversationFromCache(String conversationId) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;
    final controller = _conversationControllers[conversationId];
    if (controller == null || controller.isClosed) return;

    final rows = await _cacheService.readConversationMessages(
      userId: uid,
      conversationId: conversationId,
    );
    final projections = rows
        .map(
          (row) => DecryptedConversationMessage.fromCacheRow(
            row,
            currentUserId: uid,
          ),
        )
        .toList(growable: false);
    final signature = projections
        .map(
          (projection) => [
            projection.messageId ?? '',
            projection.clientMessageId ?? '',
            projection.messageKey,
            projection.decryptionStatus.value,
            projection.previewText,
            projection.timestamp.millisecondsSinceEpoch,
            projection.isDeleted ? 1 : 0,
            projection.isSuspicious ? 1 : 0,
          ].join('|'),
        )
        .join('||');
    if (_lastConversationEmitSignatures[conversationId] == signature) {
      return;
    }
    _lastConversationEmitSignatures[conversationId] = signature;
    controller.add(projections);
  }

  Future<void> _emitPreviewFromCache(String conversationId) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;
    final controller = _previewControllers[conversationId];
    if (controller == null || controller.isClosed) return;
    final row = await _cacheService.readConversationPreview(
      userId: uid,
      conversationId: conversationId,
    );
    final previewModel =
        row == null ? null : ConversationPreviewModel.fromCacheRow(row);
    final signature = previewModel == null
        ? null
        : [
            previewModel.lastMessageId ?? '',
            previewModel.previewText,
            previewModel.previewType,
            previewModel.decryptionStatus.value,
            previewModel.updatedAt.millisecondsSinceEpoch,
          ].join('|');
    if (_lastPreviewEmitSignatures[conversationId] == signature) {
      return;
    }
    _lastPreviewEmitSignatures[conversationId] = signature;
    controller.add(previewModel);
  }

  String _messageIdentityFromDoc(
      QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final clientMessageId =
        doc.data()['clientMessageId']?.toString().trim() ?? '';
    if (clientMessageId.isNotEmpty) {
      return clientMessageId;
    }
    return doc.id;
  }

  String _safePreviewLabel({
    required String messageType,
    required String fallback,
    String? fileName,
  }) {
    switch (messageType) {
      case 'image':
        return 'Photo';
      case 'gif':
        return 'GIF';
      case 'file':
        final trimmedFileName = fileName?.trim() ?? '';
        return trimmedFileName.isNotEmpty ? trimmedFileName : 'File';
      case 'call_summary':
        return fallback.trim().isNotEmpty ? fallback.trim() : 'Call';
      default:
        return fallback.trim();
    }
  }

  Map<String, dynamic> _normalizeRemoteMessage(
    Map<String, dynamic> rawData, {
    required String messageId,
    String? otherUserId,
  }) {
    final uid = currentUserId;
    final data = Map<String, dynamic>.from(rawData)
      ..putIfAbsent('messageId', () => messageId);

    String readString(List<String> keys) {
      for (final key in keys) {
        final value = data[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) {
          return value;
        }
      }
      return '';
    }

    final cipherText = readString(const <String>[
      'cipherText',
      'ciphertext',
      'cipher_text',
      'encryptedPayload',
      'encryptedText',
      'encrypted_payload',
      'cipher',
    ]);
    final encryptedAesKey = readString(const <String>[
      'encrypted_aes_key',
      'encryptedAesKey',
      'encrypted_aesKey',
      'encryptedAesKeyBase64',
      'encrypted_key',
      'encryptedKey',
      'e2eeEncryptedAesKey',
      'lastMessageEncryptedAesKey',
    ]);
    final iv = readString(const <String>[
      'iv',
    ]);

    if (cipherText.isNotEmpty) {
      data['cipherText'] = cipherText;
    }
    if (encryptedAesKey.isNotEmpty) {
      data['encrypted_aes_key'] = encryptedAesKey;
    }
    if (iv.isNotEmpty) {
      data['iv'] = iv;
    }

    final version = readString(const <String>[
      'e2eeVersion',
      'e2eeProtocolVersion',
      'version',
    ]);
    if (version.isNotEmpty) {
      data['e2eeVersion'] = int.tryParse(version) ?? data['e2eeVersion'];
    }

    final algorithm = readString(const <String>[
      'e2eeAlgorithm',
      'e2eeProtocol',
      'algorithm',
    ]);
    if (algorithm.isNotEmpty) {
      data['e2eeAlgorithm'] = algorithm;
    } else if ((data['cipherText']?.toString().isNotEmpty ?? false) &&
        (data['encrypted_aes_key']?.toString().isNotEmpty ?? false) &&
        (data['iv']?.toString().isNotEmpty ?? false)) {
      data['e2eeAlgorithm'] = 'rsa-aes-cbc-v1';
    }

    final normalizedType = readString(const <String>[
      'type',
      'messageType',
      'message_type',
      'messageKind',
    ]);
    final rawType = data['type']?.toString().trim() ?? '';
    final looksEncryptedTextEnvelope = (data['e2ee'] == true ||
            data['cipherText']?.toString().isNotEmpty == true) &&
        (rawType.isEmpty ||
            normalizedType == 'encrypted_text' ||
            normalizedType == 'encrypted' ||
            normalizedType == 'message' ||
            normalizedType == 'text');
    if (looksEncryptedTextEnvelope) {
      data['type'] = 'text';
    } else if (normalizedType.isNotEmpty) {
      data['type'] = normalizedType;
    }

    final senderId = readString(const <String>[
      'senderId',
      'sender',
      'senderUid',
      'senderUserId',
      'fromId',
      'fromUid',
      'from',
    ]);
    final receiverId = readString(const <String>[
      'receiverId',
      'receiver',
      'receiverUid',
      'receiverUserId',
      'toId',
      'toUid',
      'to',
    ]);
    if (senderId.isNotEmpty) {
      data['senderId'] = senderId;
    }
    if (receiverId.isNotEmpty) {
      data['receiverId'] = receiverId;
    } else if (senderId.isNotEmpty &&
        (otherUserId?.trim().isNotEmpty ?? false)) {
      data['receiverId'] = senderId == uid ? otherUserId!.trim() : uid;
    }

    final senderPublicKey = readString(const <String>[
      'senderPublicKey',
      'senderE2eePublicKey',
      'sender_public_key',
      'sender_publicKey',
      'sender_public-key',
      'localPublicKey',
      'local_public_key',
      'senderKey',
      'publicKey',
    ]);
    if (senderPublicKey.isNotEmpty) {
      data['senderPublicKey'] = senderPublicKey;
    }

    final receiverPublicKey = readString(const <String>[
      'receiverPublicKey',
      'receiverE2eePublicKey',
      'receiver_public_key',
      'receiver_publicKey',
      'receiver_public-key',
      'receiverKey',
      'peerPublicKey',
      'peer_public_key',
      'remote_public_key',
      'remotePublicKey',
    ]);
    if (receiverPublicKey.isNotEmpty) {
      data['receiverPublicKey'] = receiverPublicKey;
    }

    final clientMessageId = readString(const <String>[
      'clientMessageId',
      'lastMessageClientMessageId',
      'client_id',
      'localMessageId',
    ]);
    if (clientMessageId.isNotEmpty) {
      data['clientMessageId'] = clientMessageId;
    }

    final looksEncrypted = (data['e2ee'] == true) ||
        ((data['cipherText']?.toString().isNotEmpty ?? false) &&
            (data['encrypted_aes_key']?.toString().isNotEmpty ?? false) &&
            (data['iv']?.toString().isNotEmpty ?? false));
    if (looksEncrypted) {
      data['e2ee'] = true;
    }

    return data;
  }

  DateTime _resolveTimestamp(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw);
    }
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    }
    if (raw is String) {
      final parsedInt = int.tryParse(raw);
      if (parsedInt != null) {
        return DateTime.fromMillisecondsSinceEpoch(parsedInt);
      }
      final parsedDate = DateTime.tryParse(raw);
      if (parsedDate != null) {
        return parsedDate;
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _resolveMessageTimestamp(Map<String, dynamic> data) {
    final timestamp = _resolveTimestamp(data['timestamp']);
    if (timestamp.millisecondsSinceEpoch > 0) {
      return timestamp;
    }
    final editedAt = _resolveTimestamp(data['editedAt']);
    if (editedAt.millisecondsSinceEpoch > 0) {
      return editedAt;
    }
    final updatedAt = _resolveTimestamp(data['updatedAt']);
    if (updatedAt.millisecondsSinceEpoch > 0) {
      return updatedAt;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _deriveOtherParticipant(dynamic rawParticipants, String senderId) {
    final participants = List<String>.from(rawParticipants ?? const <String>[]);
    return participants.firstWhere(
      (id) => id != senderId,
      orElse: () => currentUserId == senderId ? '' : currentUserId,
    );
  }

  String _conversationId(String a, String b) {
    final ids = [a, b]..sort();
    return ids.join('_');
  }
}
