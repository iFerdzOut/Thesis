import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:libsignal/libsignal.dart';
import 'package:uuid/uuid.dart';

import '../models/conversation_preview_model.dart';
import '../models/decrypted_conversation_message.dart';
import '../models/prekey_bundle_model.dart';
import 'ai_detection_service.dart';
import 'key_management_service.dart';
import 'libsignal_store_service.dart';
import 'local_message_cache_service.dart';

class ChatEncryptionRepository {
  ChatEncryptionRepository._internal();

  static final ChatEncryptionRepository _instance =
      ChatEncryptionRepository._internal();
  factory ChatEncryptionRepository() => _instance;

  static const String signalAlgorithm = 'signal-v2';
  static const int signalVersion = 2;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final KeyManagementService _keyManagementService = KeyManagementService();
  final LocalMessageCacheService _cacheService = LocalMessageCacheService();
  final Uuid _uuid = const Uuid();

  final Map<String, String> _memoryPlaintextCache = <String, String>{};
  final Map<String, DateTime> _missingSessionCooldown = <String, DateTime>{};
  final Map<String, DateTime> _sessionRebuildDebounce = <String, DateTime>{};
  final Map<String, Future<List<_PreparedSignalContext>>> _pendingContextBuilds =
      <String, Future<List<_PreparedSignalContext>>>{};
  final Map<String, StreamController<List<DecryptedConversationMessage>>>
      _conversationControllers =
      <String, StreamController<List<DecryptedConversationMessage>>>{};
  final Map<String, StreamController<ConversationPreviewModel?>>
      _previewControllers =
      <String, StreamController<ConversationPreviewModel?>>{};
  final Map<String, Future<void>> _conversationSyncFutures =
      <String, Future<void>>{};
  final Map<String, Future<void>> _conversationPrewarmFutures =
      <String, Future<void>>{};
  final Map<String, int> _conversationHydrationGenerations = <String, int>{};
  final Map<String, String> _latestPreviewMessageIds = <String, String>{};
  final Map<String, String> _lastConversationEmitSignatures =
      <String, String>{};
  final Map<String, String?> _lastPreviewEmitSignatures = <String, String?>{};
  final AIDetectionService _aiDetectionService = AIDetectionService();
  final Map<String, bool> _detectionCache = <String, bool>{};
  Future<String> Function(
    Map<String, dynamic> data, {
    bool allowRepair,
  })? _legacyTextDecryptor;

  String get currentUserId => _auth.currentUser?.uid ?? '';

  Future<void> initialize() async {
    await _keyManagementService.initialize();
  }

  bool isSignalEnvelope(Map<String, dynamic> data) {
    return data['e2ee'] == true &&
        data['e2eeAlgorithm']?.toString() == signalAlgorithm &&
        (data['cipherText']?.toString().isNotEmpty ?? false);
  }

  Future<void> ensureReady() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    await initialize();
    await _keyManagementService.ensureDeviceIdentity(userId: uid);
  }

  void registerLegacyDecryptors({
    required Future<String> Function(
      Map<String, dynamic> data, {
      bool allowRepair,
    }) textDecryptor,
  }) {
    _legacyTextDecryptor = textDecryptor;
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
          chatData['lastMessageSessionAlgorithm']?.toString() == signalAlgorithm
              ? signalAlgorithm
              : chatData['lastMessageAlgorithm']?.toString(),
      'cipherText': chatData['lastMessageCipherText'],
      'e2eeCacheKey': chatData['lastMessageCacheKey'],
      'e2eeNonce': chatData['lastMessageNonce'],
      'e2eeMac': chatData['lastMessageMac'],
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
      'e2eeSessionId': chatData['lastMessageSessionId'],
      'e2eeSessionVersion': chatData['lastMessageSessionVersion'],
      'e2eeSessionPeerId': chatData['lastMessageSessionPeerId'],
      'e2eeSessionAlgorithm': chatData['lastMessageSessionAlgorithm'],
      'e2eeSessionLocalPublicKey': chatData['lastMessageSessionLocalPublicKey'],
      'e2eeSessionPeerPublicKey': chatData['lastMessageSessionPeerPublicKey'],
      'e2eeDeviceEnvelopes': chatData['lastMessageDeviceEnvelopes'],
      'e2eeMessageType': chatData['lastMessageE2eeMessageType'],
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

  Future<Map<String, dynamic>> encryptTextEnvelope({
    required String receiverId,
    required String plaintext,
  }) async {
    await ensureReady();
    final store = await _keyManagementService.getStore(currentUserId);
    final localDeviceDocId = await store.getDeviceDocId();
    final receiverContexts = await _ensureSignalContexts(
      receiverId,
      excludedDeviceDocIds: receiverId == currentUserId
          ? <String>{localDeviceDocId}
          : const <String>{},
    );
    final senderSiblingContexts = receiverId == currentUserId
        ? const <_PreparedSignalContext>[]
        : await _ensureSignalContexts(
            currentUserId,
            excludedDeviceDocIds: <String>{localDeviceDocId},
          );
    final contexts = _dedupeSignalContexts(<_PreparedSignalContext>[
      ...receiverContexts,
      ...senderSiblingContexts,
    ]);
    final clientMessageId = _uuid.v4();
    final cacheKey = _uuid.v4();
    final clearBytes = Uint8List.fromList(utf8.encode(plaintext));
    final deviceEnvelopes = <String, Map<String, dynamic>>{};
    Map<String, dynamic>? primaryEnvelope;

    for (final context in contexts) {
      try {
        final encrypted = await _buildCipher(
          context.store,
        ).encrypt(context.remoteAddress, clearBytes);
        final envelope = _buildSignalEnvelopeFields(
          context: context,
          encrypted: encrypted,
        );
        deviceEnvelopes[context.bundle.deviceDocId] = envelope;
        if (primaryEnvelope == null && context.bundle.userId == receiverId) {
          primaryEnvelope = envelope;
        }
      } catch (error) {
        debugPrint(
          '[SignalRepo] Encryption failed peer=$receiverId '
          'device=${context.bundle.signalDeviceId} error=$error',
        );
      }
    }

    if (primaryEnvelope == null) {
      throw Exception('Recipient has not enabled secure messaging yet.');
    }

    await _cacheOutgoingPlaintext(
      cacheKey: cacheKey,
      clientMessageId: clientMessageId,
      senderId: currentUserId,
      receiverId: receiverId,
      plaintext: plaintext,
      messageType: 'text',
    );

    debugPrint(
      '[SignalRepo] Encryption success peer=$receiverId '
      'devices=${deviceEnvelopes.length} clientMessageId=$clientMessageId',
    );

    return {
      'e2ee': true,
      'e2eeVersion': signalVersion,
      'e2eeProtocolVersion': signalVersion,
      'e2eeAlgorithm': signalAlgorithm,
      'e2eeProtocol': 'signal',
      'e2eeCacheKey': cacheKey,
      'clientMessageId': clientMessageId,
      ...primaryEnvelope,
      'e2eeDeviceEnvelopes': deviceEnvelopes,
    };
  }

  Future<Map<String, dynamic>> encryptBinaryEnvelope({
    required String receiverId,
    required List<int> bytes,
  }) async {
    await ensureReady();
    final context = await _ensureSignalContext(receiverId);
    final cipher = _buildCipher(context.store);
    final clientMessageId = _uuid.v4();
    final cacheKey = _uuid.v4();
    final encrypted = await cipher.encrypt(
      context.remoteAddress,
      Uint8List.fromList(bytes),
    );

    debugPrint(
      '[SignalRepo] Encryption success peer=$receiverId device=${context.bundle.signalDeviceId} '
      'type=${encrypted.type.value} clientMessageId=$clientMessageId media=1',
    );

    return {
      'e2ee': true,
      'e2eeVersion': signalVersion,
      'e2eeProtocolVersion': signalVersion,
      'e2eeAlgorithm': signalAlgorithm,
      'e2eeProtocol': 'signal',
      'cipherText': base64Encode(encrypted.ciphertext),
      'e2eeMessageType': encrypted.type.value,
      'e2eeCacheKey': cacheKey,
      'clientMessageId': clientMessageId,
      ..._buildSignalEnvelopeFields(
        context: context,
        encrypted: encrypted,
      ),
      'cipherBytes': Uint8List.fromList(encrypted.ciphertext),
    };
  }

  Future<String> decryptTextMessage(
    Map<String, dynamic> data, {
    bool allowRepair = false,
  }) async {
    await ensureReady();
    final uid = currentUserId;
    final store = await _keyManagementService.getStore(uid);
    final localDeviceDocId = await store.getDeviceDocId();
    final resolvedData = _resolveSignalEnvelopeForDevice(
      data,
      localDeviceDocId: localDeviceDocId,
    );
    final hasLocalEnvelope = _hasSignalEnvelopeForDevice(
      data,
      localDeviceDocId: localDeviceDocId,
    );
    final cacheKey = buildMessageCacheKey(resolvedData);
    final cached = await getCachedPlaintext(cacheKey);
    if (cached != null && cached.trim().isNotEmpty) {
      return cached;
    }

    final senderId = resolvedData['senderId']?.toString() ?? '';
    final receiverId = resolvedData['receiverId']?.toString() ?? '';
    if (senderId == uid && !hasLocalEnvelope) {
      return '[Encrypted message unavailable]';
    }

    try {
      final remoteAddress = ProtocolAddress(
        name: senderId,
        deviceId: (resolvedData['senderSignalDeviceId'] as num?)?.toInt() ?? 1,
      );
      final cipher = _buildCipher(store);
      final ciphertext = Uint8List.fromList(
        base64Decode(resolvedData['cipherText']?.toString() ?? ''),
      );
      final messageType =
          (resolvedData['e2eeMessageType'] as num?)?.toInt() ?? 3;
      final decrypted = await cipher.decrypt(
        remoteAddress,
        CiphertextMessage.fromRaw(
          messageType: messageType,
          ciphertext: ciphertext,
        ),
      );
      final plaintext = utf8.decode(decrypted);
      await _cacheIncomingPlaintext(
        cacheKey: cacheKey,
        messageId: resolvedData['messageId']?.toString(),
        clientMessageId: resolvedData['clientMessageId']?.toString(),
        senderId: senderId,
        receiverId: receiverId,
        plaintext: plaintext,
        messageType: 'text',
      );
      debugPrint(
        '[SignalRepo] Decryption success sender=$senderId '
        'device=${remoteAddress.deviceId()} cacheKey=$cacheKey',
      );
      return plaintext;
    } catch (error) {
      debugPrint(
        '[SignalRepo] Decryption failed sender=$senderId '
        'cacheKey=$cacheKey error=$error',
      );

      if (allowRepair && _canAttemptRepair(senderId)) {
        try {
          // Delete any broken local session so _ensureSignalContext can rebuild
          // cleanly. With containsSession = false, the next PreKeyMessage from
          // the sender will properly establish the receive-side session state.
          final repairStore = await _keyManagementService.getStore(currentUserId);
          final repairAddress = ProtocolAddress(
            name: senderId,
            deviceId: (resolvedData['senderSignalDeviceId'] as num?)?.toInt() ?? 1,
          );
          await repairStore.deleteSession(repairAddress);
          _keyManagementService.invalidateBundleCache(senderId);
          final context = await _ensureSignalContext(senderId);
          final cipher = _buildCipher(context.store);
          final ciphertext = Uint8List.fromList(
            base64Decode(resolvedData['cipherText']?.toString() ?? ''),
          );
          final messageType =
              (resolvedData['e2eeMessageType'] as num?)?.toInt() ?? 3;
          final decrypted = await cipher.decrypt(
            ProtocolAddress(
              name: senderId,
              deviceId:
                  (resolvedData['senderSignalDeviceId'] as num?)?.toInt() ??
                      context.bundle.signalDeviceId,
            ),
            CiphertextMessage.fromRaw(
              messageType: messageType,
              ciphertext: ciphertext,
            ),
          );
          final plaintext = utf8.decode(decrypted);
          await _cacheIncomingPlaintext(
            cacheKey: cacheKey,
            messageId: resolvedData['messageId']?.toString(),
            clientMessageId: resolvedData['clientMessageId']?.toString(),
            senderId: senderId,
            receiverId: receiverId,
            plaintext: plaintext,
            messageType: 'text',
          );
          return plaintext;
        } catch (_) {}
      }

      return '[Encrypted message unavailable]';
    }
  }

  Future<Uint8List> decryptBytesMessage({
    required Map<String, dynamic> data,
    required List<int> cipherBytes,
    bool allowRepair = false,
  }) async {
    await ensureReady();
    final senderId = data['senderId']?.toString() ?? '';
    if (senderId == currentUserId) {
      throw Exception('Encrypted media cache is unavailable.');
    }

    try {
      final store = await _keyManagementService.getStore(currentUserId);
      final cipher = _buildCipher(store);
      final remoteAddress = ProtocolAddress(
        name: senderId,
        deviceId: (data['senderSignalDeviceId'] as num?)?.toInt() ?? 1,
      );
      final messageType = (data['e2eeMessageType'] as num?)?.toInt() ?? 3;
      final decrypted = await cipher.decrypt(
        remoteAddress,
        CiphertextMessage.fromRaw(
          messageType: messageType,
          ciphertext: Uint8List.fromList(cipherBytes),
        ),
      );
      debugPrint(
        '[SignalRepo] Media decryption success sender=$senderId '
        'device=${remoteAddress.deviceId()}',
      );
      return decrypted;
    } catch (error) {
      debugPrint(
          '[SignalRepo] Media decryption failed sender=$senderId error=$error');
      if (allowRepair && _canAttemptRepair(senderId)) {
        await _ensureSignalContext(senderId);
        final store = await _keyManagementService.getStore(currentUserId);
        final cipher = _buildCipher(store);
        final remoteAddress = ProtocolAddress(
          name: senderId,
          deviceId: (data['senderSignalDeviceId'] as num?)?.toInt() ?? 1,
        );
        final messageType = (data['e2eeMessageType'] as num?)?.toInt() ?? 3;
        return cipher.decrypt(
          remoteAddress,
          CiphertextMessage.fromRaw(
            messageType: messageType,
            ciphertext: Uint8List.fromList(cipherBytes),
          ),
        );
      }
      rethrow;
    }
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
      failureReason: null,
      timestamp: DateTime.fromMillisecondsSinceEpoch(resolvedTimestampMs),
      isOutgoing: senderId.trim() == uid,
      isDeleted: false,
      isSuspicious: false,
    );
    await _persistProjection(projection);
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
    final timestamp = _resolveMessageTimestamp(normalized);
    final cacheKey = buildMessageCacheKey(normalized);
    final legacyEnvelope = isLegacyEnvelope(normalized);

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
      final retryCooldown = legacyEnvelope
          ? const Duration(seconds: 5)
          : const Duration(seconds: 30);
      final recentFailure =
          projection.decryptionStatus == ConversationDecryptionStatus.failed &&
              DateTime.now().difference(lastUpdatedAt) < retryCooldown;
      if ((sameCacheKey || sameClientMessageId) &&
          (projection.decryptionStatus ==
                  ConversationDecryptionStatus.success ||
              recentFailure)) {
        return projection;
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
      );
      await _persistProjection(projection);
      return projection;
    }

    final cachedPlaintext = await getCachedPlaintext(cacheKey);
    if (cachedPlaintext != null && cachedPlaintext.trim().isNotEmpty) {
      final resolvedSuspicious = senderId != uid
          ? await _detectIncoming(messageId, cachedPlaintext, senderId,
              fallback: isSuspicious)
          : isSuspicious;
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
        isSuspicious: resolvedSuspicious,
      );
      await _persistProjection(projection);
      return projection;
    }

    final shouldRetry = _isFreshEncryptedMessage(timestamp);
    String? decryptedText;
    if (isSignalEnvelope(normalized)) {
      final signalText = await decryptTextMessage(
        normalized,
        allowRepair: shouldRetry,
      );
      if (!_isUnavailablePlaceholder(signalText)) {
        decryptedText = signalText;
      }
    } else if (_legacyTextDecryptor != null && legacyEnvelope) {
      final legacyText = await _legacyTextDecryptor!(
        normalized,
        allowRepair: shouldRetry,
      );
      if (!_isUnavailablePlaceholder(legacyText)) {
        decryptedText = legacyText;
      }
    }

    if (decryptedText != null && decryptedText.trim().isNotEmpty) {
      final resolvedSuspicious = senderId != uid
          ? await _detectIncoming(messageId, decryptedText, senderId,
              fallback: isSuspicious)
          : isSuspicious;
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
        isSuspicious: resolvedSuspicious,
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
      previewText: 'Encrypted message',
      decryptionStatus: ConversationDecryptionStatus.failed,
      failureReason: shouldRetry
          ? 'Unable to decrypt message'
          : 'Unable to decrypt older message',
      timestamp: timestamp,
      isOutgoing: senderId == uid,
      isDeleted: false,
      isSuspicious: isSuspicious,
    );
    await _persistProjection(projection);
    return projection;
  }

  /// Runs AI smishing detection on an incoming (other-user) message.
  /// Results are cached by [messageId] so the model is not invoked repeatedly
  /// for the same message as the Firestore snapshot refreshes.
  Future<bool> _detectIncoming(
    String messageId,
    String plaintext,
    String senderId, {
    bool fallback = false,
  }) async {
    if (_detectionCache.containsKey(messageId)) {
      return _detectionCache[messageId]!;
    }
    try {
      final result = await _aiDetectionService.detectSmishing(
        plaintext,
        sender: senderId,
      );
      _detectionCache[messageId] = result;
      return result;
    } catch (e) {
      debugPrint(
          '[ChatEncryptRepo] Detection failed for $messageId, using fallback: $e');
      return fallback;
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

  bool isLegacyEnvelope(Map<String, dynamic> data) {
    return (data['cipherText']?.toString().isNotEmpty ?? false) &&
        (data['e2eeNonce']?.toString().isNotEmpty ?? false) &&
        (data['e2eeMac']?.toString().isNotEmpty ?? false);
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
      await ensureReady();
      await _ensureSignalContext(trimmedPeerUserId);
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
    final latestDoc = orderedDocs.first;
    final cachedRows = await _cacheService.readConversationMessages(
      userId: currentUserId,
      conversationId: conversationId,
    );
    final cachedIndexes = _buildProjectionRowIndexes(cachedRows);

    if (docChanges == null) {
      final generation = _nextConversationHydrationGeneration(conversationId);
      final newestDocs = orderedDocs.take(20).toList(growable: false);
      final olderDocs = orderedDocs.skip(20).toList(growable: false);

      final warmedNewest = await _processConversationDocs(
        conversationId: conversationId,
        otherUserId: otherUserId,
        docs: newestDocs,
        cachedIndexes: cachedIndexes,
      );
      if (warmedNewest) {
        await _emitConversationFromCache(conversationId);
      }

      await _syncLatestPreviewFromDoc(
        conversationId: conversationId,
        otherUserId: otherUserId,
        latestDoc: latestDoc,
      );

      if (olderDocs.isNotEmpty) {
        await _hydrateOlderConversationHistory(
          conversationId: conversationId,
          otherUserId: otherUserId,
          docs: olderDocs,
          cachedIndexes: cachedIndexes,
          generation: generation,
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
      cachedIndexes: cachedIndexes,
    );
    if (processedAny) {
      await _emitConversationFromCache(conversationId);
    }

    final currentLatestIdentity = _messageIdentityFromDoc(latestDoc);
    final shouldRefreshLatestPreview = currentLatestIdentity !=
            (_latestPreviewMessageIds[conversationId] ?? '') ||
        docChanges.any((change) => change.doc.id == latestDoc.id) ||
        docChanges.any((change) => change.type == DocumentChangeType.removed);
    if (shouldRefreshLatestPreview) {
      await _syncLatestPreviewFromDoc(
        conversationId: conversationId,
        otherUserId: otherUserId,
        latestDoc: latestDoc,
      );
    }
  }

  Future<void> _hydrateOlderConversationHistory({
    required String conversationId,
    required String otherUserId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required _ProjectionRowIndexes cachedIndexes,
    required int generation,
  }) async {
    if (docs.isEmpty) return;

    for (var i = 0; i < docs.length; i += 20) {
      if ((_conversationHydrationGenerations[conversationId] ?? -1) !=
          generation) {
        return;
      }
      final batch = docs.skip(i).take(20).toList(growable: false);
      final processedAny = await _processConversationDocs(
        conversationId: conversationId,
        otherUserId: otherUserId,
        docs: batch,
        cachedIndexes: cachedIndexes,
      );
      if (processedAny) {
        await _emitConversationFromCache(conversationId);
      }
      await Future<void>.delayed(Duration.zero);
    }

    if ((_conversationHydrationGenerations[conversationId] ?? -1) !=
        generation) {
      return;
    }
    await _emitConversationFromCache(conversationId);
  }

  Future<bool> _processConversationDocs({
    required String conversationId,
    required String otherUserId,
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required _ProjectionRowIndexes cachedIndexes,
  }) async {
    if (docs.isEmpty) {
      return false;
    }

    var processedAny = false;
    for (final doc in docs) {
      final rawData = Map<String, dynamic>.from(doc.data())
        ..putIfAbsent('messageId', () => doc.id);
      final normalized = _normalizeRemoteMessage(
        rawData,
        messageId: doc.id,
        otherUserId: otherUserId,
      );
      if (_hasReusableSuccessfulProjection(
        docId: doc.id,
        normalized: normalized,
        cachedIndexes: cachedIndexes,
      )) {
        continue;
      }

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

  _ProjectionRowIndexes _buildProjectionRowIndexes(
    List<Map<String, dynamic>> rows,
  ) {
    final byMessageId = <String, Map<String, dynamic>>{};
    final byClientMessageId = <String, Map<String, dynamic>>{};
    final byMessageKey = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      final messageId = row['message_id']?.toString().trim() ?? '';
      if (messageId.isNotEmpty) {
        byMessageId[messageId] = row;
      }
      final clientMessageId = row['client_message_id']?.toString().trim() ?? '';
      if (clientMessageId.isNotEmpty) {
        byClientMessageId[clientMessageId] = row;
      }
      final messageKey = row['message_key']?.toString().trim() ?? '';
      if (messageKey.isNotEmpty) {
        byMessageKey[messageKey] = row;
      }
    }
    return _ProjectionRowIndexes(
      byMessageId: byMessageId,
      byClientMessageId: byClientMessageId,
      byMessageKey: byMessageKey,
    );
  }

  bool _hasReusableSuccessfulProjection({
    required String docId,
    required Map<String, dynamic> normalized,
    required _ProjectionRowIndexes cachedIndexes,
  }) {
    final uid = currentUserId;
    if (uid.isEmpty) return false;

    final currentClientMessageId =
        normalized['clientMessageId']?.toString().trim() ?? '';
    final currentMessageKey = buildMessageCacheKey(normalized).trim();
    final currentIsDeleted = normalized['isDeleted'] == true ||
        (normalized['type']?.toString() ?? '') == 'deleted';

    Map<String, dynamic>? row = cachedIndexes.byMessageId[docId];
    if (row != null) {
      final rowClientMessageId =
          row['client_message_id']?.toString().trim() ?? '';
      final rowMessageKey = row['message_key']?.toString().trim() ?? '';
      final sameClient = currentClientMessageId.isNotEmpty &&
          rowClientMessageId == currentClientMessageId;
      final sameKey =
          currentMessageKey.isNotEmpty && rowMessageKey == currentMessageKey;
      if (!sameClient && !sameKey) {
        row = null;
      }
    }
    row ??= currentClientMessageId.isNotEmpty
        ? cachedIndexes.byClientMessageId[currentClientMessageId]
        : null;
    row ??= currentMessageKey.isNotEmpty
        ? cachedIndexes.byMessageKey[currentMessageKey]
        : null;
    if (row == null) {
      return false;
    }

    final projection = DecryptedConversationMessage.fromCacheRow(
      row,
      currentUserId: uid,
    );
    return projection.decryptionStatus ==
            ConversationDecryptionStatus.success &&
        projection.isDeleted == currentIsDeleted;
  }

  int _nextConversationHydrationGeneration(String conversationId) {
    final next = (_conversationHydrationGenerations[conversationId] ?? 0) + 1;
    _conversationHydrationGenerations[conversationId] = next;
    return next;
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
      'encryptedPayload',
      'encryptedText',
      'encrypted_payload',
      'cipher',
    ]);
    final nonce = readString(const <String>[
      'e2eeNonce',
      'nonce',
      'iv',
    ]);
    final mac = readString(const <String>[
      'e2eeMac',
      'mac',
      'tag',
    ]);

    if (cipherText.isNotEmpty) {
      data['cipherText'] = cipherText;
    } else if ((data['e2ee'] == true || nonce.isNotEmpty || mac.isNotEmpty) &&
        (data['text']?.toString().trim().isNotEmpty ?? false)) {
      data['cipherText'] = data['text']?.toString().trim();
      data['text'] = '';
    }
    if (nonce.isNotEmpty) {
      data['e2eeNonce'] = nonce;
    }
    if (mac.isNotEmpty) {
      data['e2eeMac'] = mac;
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
        (data['e2eeNonce']?.toString().isNotEmpty ?? false) &&
        (data['e2eeMac']?.toString().isNotEmpty ?? false)) {
      data['e2eeAlgorithm'] = 'x25519-aesgcm-v1';
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

    final sessionLocalPublicKey = readString(const <String>[
      'e2eeSessionLocalPublicKey',
      'sessionLocalPublicKey',
      'session_local_public_key',
      'sessionLocalKey',
      'localPublicKey',
      'local_public_key',
    ]);
    if (sessionLocalPublicKey.isNotEmpty) {
      data['e2eeSessionLocalPublicKey'] = sessionLocalPublicKey;
    }

    final sessionPeerPublicKey = readString(const <String>[
      'e2eeSessionPeerPublicKey',
      'sessionPeerPublicKey',
      'session_peer_public_key',
      'sessionPeerKey',
      'peerPublicKey',
      'peer_public_key',
    ]);
    if (sessionPeerPublicKey.isNotEmpty) {
      data['e2eeSessionPeerPublicKey'] = sessionPeerPublicKey;
    }

    final sessionId = readString(const <String>[
      'e2eeSessionId',
      'sessionId',
      'session_id',
    ]);
    if (sessionId.isNotEmpty) {
      data['e2eeSessionId'] = sessionId;
    }

    final sessionAlgorithm = readString(const <String>[
      'e2eeSessionAlgorithm',
      'sessionAlgorithm',
      'session_algorithm',
    ]);
    if (sessionAlgorithm.isNotEmpty) {
      data['e2eeSessionAlgorithm'] = sessionAlgorithm;
    }

    final sessionVersion = readString(const <String>[
      'e2eeSessionVersion',
      'sessionVersion',
      'session_version',
    ]);
    if (sessionVersion.isNotEmpty) {
      data['e2eeSessionVersion'] =
          int.tryParse(sessionVersion) ?? data['e2eeSessionVersion'];
    }

    final sessionPeerId = readString(const <String>[
      'e2eeSessionPeerId',
      'sessionPeerId',
      'session_peer_id',
    ]);
    if (sessionPeerId.isNotEmpty) {
      data['e2eeSessionPeerId'] = sessionPeerId;
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
        (data['cipherText']?.toString().isNotEmpty ?? false);
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

  bool _isFreshEncryptedMessage(DateTime timestamp) {
    final now = DateTime.now();
    final age = now.isAfter(timestamp)
        ? now.difference(timestamp)
        : timestamp.difference(now);
    return age <= const Duration(hours: 1);
  }

  bool _isUnavailablePlaceholder(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('[') && trimmed.endsWith(']');
  }

  String _deriveOtherParticipant(dynamic rawParticipants, String senderId) {
    final participants = List<String>.from(rawParticipants ?? const <String>[]);
    return participants.firstWhere(
      (id) => id != senderId,
      orElse: () => currentUserId == senderId ? '' : currentUserId,
    );
  }

  SessionCipher _buildCipher(LibsignalStoreService store) {
    return SessionCipher(
      sessionStore: store,
      identityKeyStore: store,
      preKeyStore: store,
      signedPreKeyStore: store,
      kyberPreKeyStore: store,
    );
  }

  Future<_PreparedSignalContext> _ensureSignalContext(String peerUserId) async {
    final contexts = await _ensureSignalContexts(peerUserId);
    if (contexts.isEmpty) {
      throw Exception('Recipient has not enabled secure messaging yet.');
    }
    return contexts.first;
  }

  Future<List<_PreparedSignalContext>> _ensureSignalContexts(
    String peerUserId, {
    Set<String> excludedDeviceDocIds = const <String>{},
  }) {
    // Coalesce concurrent builds for the same peer so racing sendMessage()
    // calls share one in-flight Firestore fetch + session build instead of
    // racing and overwriting each other's sessions.
    final pending = _pendingContextBuilds[peerUserId];
    if (pending != null) return pending;

    final future = _doEnsureSignalContexts(
      peerUserId,
      excludedDeviceDocIds: excludedDeviceDocIds,
    );
    _pendingContextBuilds[peerUserId] = future;
    future.whenComplete(() => _pendingContextBuilds.remove(peerUserId));
    return future;
  }

  Future<List<_PreparedSignalContext>> _doEnsureSignalContexts(
    String peerUserId, {
    Set<String> excludedDeviceDocIds = const <String>{},
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    await _keyManagementService.ensureDeviceIdentity(userId: uid);
    final store = await _keyManagementService.getStore(uid);
    final localDeviceDocId = await store.getDeviceDocId();
    final localSignalDeviceId = await store.getSignalDeviceId();
    final localIdentityPublicKeyBase64 =
        await _keyManagementService.getCurrentIdentityPublicKeyBase64(uid);

    final liveBundles = await _keyManagementService.fetchPeerBundles(
      peerUserId,
      consumeOneTimePreKey: false,
    );
    if (liveBundles.isEmpty) {
      throw Exception('Recipient has not enabled secure messaging yet.');
    }

    final excluded = excludedDeviceDocIds
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toSet();
    final contexts = <_PreparedSignalContext>[];
    for (final initialBundle in liveBundles) {
      if (excluded.contains(initialBundle.deviceDocId)) {
        continue;
      }
      var liveBundle = initialBundle;
      final remoteAddress = liveBundle.toProtocolAddress();
      final hasSession = await store.containsSession(remoteAddress);

      if (!hasSession) {
        final debounceKey = '$peerUserId:${liveBundle.signalDeviceId}';
        final lastRebuild = _sessionRebuildDebounce[debounceKey];
        if (lastRebuild != null &&
            DateTime.now().difference(lastRebuild) <
                const Duration(seconds: 30)) {
          // A rebuild was just attempted for this peer+device. Skip to avoid
          // a rebuild storm while the session is being established.
          continue;
        }
        _sessionRebuildDebounce[debounceKey] = DateTime.now();
        try {
          liveBundle = await _keyManagementService.fetchPeerBundleForDevice(
                peerUserId,
                deviceDocId: liveBundle.deviceDocId,
                consumeOneTimePreKey: true,
              ) ??
              liveBundle;
          final sessionBuilder = SessionBuilder(
            sessionStore: store,
            identityKeyStore: store,
          );
          await sessionBuilder.processPreKeyBundle(
            liveBundle.toProtocolAddress(),
            liveBundle.toSignalPreKeyBundle(),
          );
          debugPrint(
            '[SignalRepo] Session ready peer=$peerUserId '
            'device=${liveBundle.signalDeviceId} preKey=${liveBundle.oneTimePreKeyId}',
          );
        } catch (e) {
          // The bundle for this device is corrupted or has a mismatched
          // signature (e.g. stale Firestore doc from a previous registration).
          // Log and skip — other devices may still succeed. Reset the debounce
          // so the next send can retry this device after new keys are published.
          debugPrint(
            '[SignalRepo] Session build failed peer=$peerUserId '
            'device=${liveBundle.signalDeviceId} error=$e — skipping device',
          );
          _sessionRebuildDebounce.remove(debounceKey);
          continue;
        }
      }

      contexts.add(
        _PreparedSignalContext(
          store: store,
          remoteAddress: liveBundle.toProtocolAddress(),
          bundle: liveBundle,
          localDeviceDocId: localDeviceDocId,
          localSignalDeviceId: localSignalDeviceId,
          localIdentityPublicKeyBase64: localIdentityPublicKeyBase64,
        ),
      );
    }

    return contexts;
  }

  Map<String, dynamic> _buildSignalEnvelopeFields({
    required _PreparedSignalContext context,
    required CiphertextMessage encrypted,
  }) {
    return <String, dynamic>{
      'cipherText': base64Encode(encrypted.ciphertext),
      'e2eeMessageType': encrypted.type.value,
      'senderDeviceDocId': context.localDeviceDocId,
      'receiverDeviceDocId': context.bundle.deviceDocId,
      'senderSignalDeviceId': context.localSignalDeviceId,
      'receiverSignalDeviceId': context.bundle.signalDeviceId,
      'senderPublicKey': context.localIdentityPublicKeyBase64,
      'receiverPublicKey': context.bundle.identityPublicKeyBase64,
      'e2eeSessionId':
          '${context.bundle.userId}_${context.bundle.deviceDocId}_${context.bundle.signalDeviceId}',
      'e2eePreKeyIdUsed': context.bundle.oneTimePreKeyId,
      'e2eeSignedPreKeyIdUsed': context.bundle.signedPreKeyId,
    };
  }

  List<_PreparedSignalContext> _dedupeSignalContexts(
    List<_PreparedSignalContext> contexts,
  ) {
    final deduped = <String, _PreparedSignalContext>{};
    for (final context in contexts) {
      deduped.putIfAbsent(context.bundle.deviceDocId, () => context);
    }
    return deduped.values.toList(growable: false);
  }

  bool _hasSignalEnvelopeForDevice(
    Map<String, dynamic> data, {
    required String localDeviceDocId,
  }) {
    final raw = data['e2eeDeviceEnvelopes'];
    if (raw is! Map) {
      return false;
    }
    final selected = raw[localDeviceDocId];
    return selected is Map && selected.isNotEmpty;
  }

  Map<String, dynamic> _resolveSignalEnvelopeForDevice(
    Map<String, dynamic> data, {
    required String localDeviceDocId,
  }) {
    final raw = data['e2eeDeviceEnvelopes'];
    if (raw is! Map) {
      return data;
    }
    final selected = raw[localDeviceDocId];
    if (selected is! Map) {
      return data;
    }
    final resolved = Map<String, dynamic>.from(data);
    resolved.addAll(
      selected.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
    );
    return resolved;
  }

  Future<void> _cacheOutgoingPlaintext({
    required String cacheKey,
    required String clientMessageId,
    required String senderId,
    required String receiverId,
    required String plaintext,
    required String messageType,
  }) async {
    await cachePlaintext(
      cacheKey: cacheKey,
      conversationId: _conversationId(senderId, receiverId),
      messageId: null,
      clientMessageId: clientMessageId,
      senderId: senderId,
      receiverId: receiverId,
      plaintext: plaintext,
      messageType: messageType,
      updateConversationPreview: true,
    );
  }

  Future<void> _cacheIncomingPlaintext({
    required String cacheKey,
    required String? messageId,
    required String? clientMessageId,
    required String senderId,
    required String receiverId,
    required String plaintext,
    required String messageType,
  }) async {
    await cachePlaintext(
      cacheKey: cacheKey,
      conversationId: _conversationId(senderId, receiverId),
      messageId: messageId,
      clientMessageId: clientMessageId,
      senderId: senderId,
      receiverId: receiverId,
      plaintext: plaintext,
      messageType: messageType,
      updateConversationPreview: false,
    );
  }

  bool _canAttemptRepair(String peerUserId) {
    final lastAttempt = _missingSessionCooldown[peerUserId];
    if (lastAttempt != null &&
        DateTime.now().difference(lastAttempt) < const Duration(seconds: 5)) {
      return false;
    }
    _missingSessionCooldown[peerUserId] = DateTime.now();
    return true;
  }

  /// Deletes all local Signal sessions for [peerUserId] and clears the bundle
  /// cache. The next outgoing message to that peer will produce a fresh
  /// PreKeyMessage (new X3DH exchange), allowing the receiver to re-establish
  /// their session automatically.
  Future<void> resetPeerSession(String peerUserId) async {
    final trimmed = peerUserId.trim();
    if (trimmed.isEmpty) return;
    await ensureReady();
    final store = await _keyManagementService.getStore(currentUserId);
    final bundles = await _keyManagementService.fetchPeerBundles(
      trimmed,
      consumeOneTimePreKey: false,
    );
    for (final bundle in bundles) {
      try {
        await store.deleteSession(bundle.toProtocolAddress());
      } catch (_) {}
    }
    _keyManagementService.invalidateBundleCache(trimmed);
    _missingSessionCooldown.remove(trimmed);
  }

  String _conversationId(String a, String b) {
    final ids = [a, b]..sort();
    return ids.join('_');
  }
}

class _PreparedSignalContext {
  final LibsignalStoreService store;
  final ProtocolAddress remoteAddress;
  final PreKeyBundleModel bundle;
  final String localDeviceDocId;
  final int localSignalDeviceId;
  final String localIdentityPublicKeyBase64;

  const _PreparedSignalContext({
    required this.store,
    required this.remoteAddress,
    required this.bundle,
    required this.localDeviceDocId,
    required this.localSignalDeviceId,
    required this.localIdentityPublicKeyBase64,
  });
}

class _ProjectionRowIndexes {
  final Map<String, Map<String, dynamic>> byMessageId;
  final Map<String, Map<String, dynamic>> byClientMessageId;
  final Map<String, Map<String, dynamic>> byMessageKey;

  const _ProjectionRowIndexes({
    required this.byMessageId,
    required this.byClientMessageId,
    required this.byMessageKey,
  });
}
