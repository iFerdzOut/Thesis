import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'chat_encryption_repository.dart';
import 'key_management_service.dart';

class EncryptedTextPayload {
  final String cipherText;
  final String nonce;
  final String mac;
  final int version;
  final String algorithm;

  const EncryptedTextPayload({
    required this.cipherText,
    required this.nonce,
    required this.mac,
    this.version = 1,
    this.algorithm = 'x25519-aesgcm-v1',
  });

  Map<String, dynamic> toMap() {
    return {
      'e2ee': true,
      'e2eeVersion': version,
      'e2eeAlgorithm': algorithm,
      'cipherText': cipherText,
      'e2eeNonce': nonce,
      'e2eeMac': mac,
    };
  }
}

class EncryptedBinaryPayload {
  final Uint8List cipherBytes;
  final String nonce;
  final String mac;
  final int version;
  final String algorithm;

  const EncryptedBinaryPayload({
    required this.cipherBytes,
    required this.nonce,
    required this.mac,
    this.version = 1,
    this.algorithm = 'x25519-aesgcm-v1',
  });

  Map<String, dynamic> toMap() {
    return {
      'e2ee': true,
      'e2eeVersion': version,
      'e2eeAlgorithm': algorithm,
      'e2eeNonce': nonce,
      'e2eeMac': mac,
    };
  }
}

class E2eeSessionContext {
  final String peerId;
  final String chatId;
  final String sessionId;
  final String localPublicKeyBase64;
  final String peerPublicKeyBase64;
  final SimpleKeyPairData localKeyPair;
  final SimplePublicKey peerPublicKey;
  final int sessionVersion;
  final String algorithm;

  const E2eeSessionContext({
    required this.peerId,
    required this.chatId,
    required this.sessionId,
    required this.localPublicKeyBase64,
    required this.peerPublicKeyBase64,
    required this.localKeyPair,
    required this.peerPublicKey,
    this.sessionVersion = 1,
    this.algorithm = 'x25519-aesgcm-v1',
  });

  Map<String, dynamic> toMetadataMap() {
    return {
      'senderPublicKey': localPublicKeyBase64,
      'receiverPublicKey': peerPublicKeyBase64,
      'e2eeSessionChatId': chatId,
      'e2eeSessionLocalPublicKey': localPublicKeyBase64,
      'e2eeSessionPeerPublicKey': peerPublicKeyBase64,
      'e2eeSessionId': sessionId,
      'e2eeSessionVersion': sessionVersion,
      'e2eeSessionPeerId': peerId,
      'e2eeSessionAlgorithm': algorithm,
      'e2eeKeyType': 'static_x25519',
    };
  }
}

class _PeerPublicKeyCandidates {
  final List<SimplePublicKey> exact;
  final List<SimplePublicKey> fallback;

  const _PeerPublicKeyCandidates({
    required this.exact,
    required this.fallback,
  });
}

class E2eeService {
  E2eeService._internal() {
    _signalRepository.registerLegacyDecryptors(
      textDecryptor: _decryptTextMessageLegacy,
    );
  }

  static final E2eeService _instance = E2eeService._internal();
  factory E2eeService() => _instance;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _privateKeyPrefix = 'e2ee_private_';
  static const String _publicKeyPrefix = 'e2ee_public_';
  static const String _localKeyHistoryPrefix = 'e2ee_key_history_';
  static const String _accountBackupPassphrasePrefix =
      'e2ee_account_backup_passphrase_';
  static const String _bootstrappedMarkerPrefix = 'e2ee_bootstrapped_v1_';
  static const String _algorithm = 'x25519-aesgcm-v1';
  static const String _recoveryAlgorithm = 'pbkdf2-aesgcm-v1';
  static const int _recoveryVersion = 1;
  static const int _recoveryIterations = 150000;
  static const int _maxStoredLocalKeyHistoryEntries = 6;
  static const Duration _autoRepairFreshWindow = Duration(hours: 1);

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ChatEncryptionRepository _signalRepository = ChatEncryptionRepository();
  final KeyManagementService _keyManagementService = KeyManagementService();
  final X25519 _keyExchange = X25519();
  final AesGcm _cipher = AesGcm.with256bits();
  final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final Pbkdf2 _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _recoveryIterations,
    bits: 256,
  );
  final Random _random = Random.secure();
  String? _ensuredUserId;
  Future<void>? _ensureIdentityFuture;
  String? _syncedRemoteIdentityUserId;
  String? _syncedRemoteIdentityPublicKey;
  Future<void>? _remoteIdentitySyncFuture;
  String? _cachedKeyPairUserId;
  SimpleKeyPairData? _cachedCurrentUserKeyPair;
  Future<SimpleKeyPairData>? _keyPairFuture;
  final Map<String, SimplePublicKey> _publicKeyCache =
      <String, SimplePublicKey>{};
  final Map<String, Future<SimplePublicKey?>> _publicKeyFutureCache =
      <String, Future<SimplePublicKey?>>{};
  final Map<String, List<SimplePublicKey>> _previousPublicKeysCache =
      <String, List<SimplePublicKey>>{};
  final Map<String, Future<List<SimplePublicKey>>> _previousPublicKeysFutureCache =
      <String, Future<List<SimplePublicKey>>>{};
  final Map<String, SecretKey> _conversationKeyCache = <String, SecretKey>{};
  final Map<String, String> _decryptedTextCache = <String, String>{};
  final Map<String, E2eeSessionContext> _sessionCache =
      <String, E2eeSessionContext>{};
  List<SimpleKeyPairData>? _cachedLocalKeyHistory;
  String? _cachedLocalKeyHistoryUserId;
  final Map<String, Future<void>> _peerRepairFutureCache =
      <String, Future<void>>{};
  final Map<String, DateTime> _peerRepairTimestamps = <String, DateTime>{};
  Future<void>? _automaticBackupSyncFuture;
  Future<bool>? _automaticBackupBootstrapFuture;

  static const Duration _repairCooldown = Duration(seconds: 5);

  String get currentUserId => _auth.currentUser?.uid ?? '';

  Future<E2eeSessionContext> ensureSessionForPeer({
    required String peerId,
    String? preferredPeerPublicKeyBase64,
  }) async {
    final trimmedPeerId = peerId.trim();
    if (trimmedPeerId.isEmpty) {
      throw Exception('Peer ID is required for encrypted chat.');
    }

    await ensureIdentityForCurrentUser();
    final userId = currentUserId;
    final localKeyPair = await _readCurrentUserKeyPair();
    final localPublicKeyB64 = base64Encode(localKeyPair.publicKey.bytes);

    SimplePublicKey? peerPublicKey;
    String peerPublicKeyB64 = preferredPeerPublicKeyBase64?.trim() ?? '';
    if (peerPublicKeyB64.isNotEmpty) {
      try {
        peerPublicKey = SimplePublicKey(
          base64Decode(peerPublicKeyB64),
          type: KeyPairType.x25519,
        );
      } catch (_) {
        peerPublicKey = null;
        peerPublicKeyB64 = '';
      }
    }

    peerPublicKey ??= await _readUserPublicKey(
      trimmedPeerId,
      forceRefresh: true,
    );
    if (peerPublicKey == null) {
      throw Exception('Recipient has not enabled encrypted chat yet.');
    }
    if (peerPublicKeyB64.isEmpty) {
      peerPublicKeyB64 = base64Encode(peerPublicKey.bytes);
    }

    final chatId = _chatId(userId, trimmedPeerId);
    final sessionCacheKey = _buildSessionCacheKey(
      chatId: chatId,
      localPublicKeyBase64: localPublicKeyB64,
      peerPublicKeyBase64: peerPublicKeyB64,
    );
    final cachedSession = _sessionCache[sessionCacheKey];
    if (cachedSession != null) {
      return cachedSession;
    }

    final session = E2eeSessionContext(
      peerId: trimmedPeerId,
      chatId: chatId,
      sessionId: _buildSessionId(
        chatId: chatId,
        localPublicKeyBase64: localPublicKeyB64,
        peerPublicKeyBase64: peerPublicKeyB64,
      ),
      localPublicKeyBase64: localPublicKeyB64,
      peerPublicKeyBase64: peerPublicKeyB64,
      localKeyPair: localKeyPair,
      peerPublicKey: peerPublicKey,
      sessionVersion: 1,
      algorithm: _algorithm,
    );

    _sessionCache[sessionCacheKey] = session;
    await _persistSessionSnapshot(session);
    return session;
  }

  Future<Map<String, dynamic>> encryptTextEnvelope({
    required String receiverId,
    required String plaintext,
  }) async {
    try {
      await _keyManagementService.ensureDeviceIdentity(
        userId: currentUserId,
        forceRepublish: false,
      );
      final envelope = await _signalRepository.encryptTextEnvelope(
        receiverId: receiverId,
        plaintext: plaintext,
      );
      unawaited(syncAutomaticAccountBackupIfAvailable());
      return envelope;
    } catch (error) {
      debugPrint('[E2eeService] Signal text encrypt fallback: $error');
    }

    final envelope = await _encryptTextEnvelopeLegacy(
      receiverId: receiverId,
      plaintext: plaintext,
    );
    unawaited(syncAutomaticAccountBackupIfAvailable());
    return envelope;
  }

  Future<Map<String, dynamic>> _encryptTextEnvelopeLegacy({
    required String receiverId,
    required String plaintext,
  }) async {
    await ensureIdentityForCurrentUser(syncRemote: true);
    final session = await ensureSessionForPeer(peerId: receiverId);
    final conversationKey = await _deriveConversationKey(
      keyPair: session.localKeyPair,
      peerPublicKey: session.peerPublicKey,
      otherUserId: receiverId,
    );
    final nonce = _randomBytes(12);
    final secretBox = await _cipher.encrypt(
      utf8.encode(plaintext),
      secretKey: conversationKey,
      nonce: nonce,
    );

    return {
      ...EncryptedTextPayload(
        cipherText: base64Encode(secretBox.cipherText),
        nonce: base64Encode(secretBox.nonce),
        mac: base64Encode(secretBox.mac.bytes),
        version: session.sessionVersion,
        algorithm: session.algorithm,
      ).toMap(),
      ...session.toMetadataMap(),
    };
  }

  Future<Map<String, dynamic>> encryptBinaryEnvelope({
    required String receiverId,
    required List<int> bytes,
  }) async {
    try {
      await _keyManagementService.ensureDeviceIdentity(
        userId: currentUserId,
        forceRepublish: false,
      );
      final envelope = await _signalRepository.encryptBinaryEnvelope(
        receiverId: receiverId,
        bytes: bytes,
      );
      unawaited(syncAutomaticAccountBackupIfAvailable());
      return envelope;
    } catch (error) {
      debugPrint('[E2eeService] Signal media encrypt fallback: $error');
    }

    final envelope = await _encryptBinaryEnvelopeLegacy(
      receiverId: receiverId,
      bytes: bytes,
    );
    unawaited(syncAutomaticAccountBackupIfAvailable());
    return envelope;
  }

  Future<Map<String, dynamic>> _encryptBinaryEnvelopeLegacy({
    required String receiverId,
    required List<int> bytes,
  }) async {
    await ensureIdentityForCurrentUser(syncRemote: true);
    final session = await ensureSessionForPeer(peerId: receiverId);
    final conversationKey = await _deriveConversationKey(
      keyPair: session.localKeyPair,
      peerPublicKey: session.peerPublicKey,
      otherUserId: receiverId,
    );
    final nonce = _randomBytes(12);
    final secretBox = await _cipher.encrypt(
      bytes,
      secretKey: conversationKey,
      nonce: nonce,
    );

    return {
      ...EncryptedBinaryPayload(
        cipherBytes: Uint8List.fromList(secretBox.cipherText),
        nonce: base64Encode(secretBox.nonce),
        mac: base64Encode(secretBox.mac.bytes),
        version: session.sessionVersion,
        algorithm: session.algorithm,
      ).toMap(),
      ...session.toMetadataMap(),
      'cipherBytes': Uint8List.fromList(secretBox.cipherText),
    };
  }

  Future<String> getCurrentUserPublicKeyBase64() async {
    await ensureIdentityForCurrentUser();
    final keyPair = await _readCurrentUserKeyPair();
    return base64Encode(keyPair.publicKey.bytes);
  }

  Future<String?> getUserPublicKeyBase64(
    String uid, {
    bool forceRefresh = false,
  }) async {
    final publicKey = await _readUserPublicKey(uid, forceRefresh: forceRefresh);
    if (publicKey == null) return null;
    return base64Encode(publicKey.bytes);
  }

  Future<void> saveRecoveryKeyBackup({
    required String passphrase,
  }) async {
    final trimmed = passphrase.trim();
    if (trimmed.length < 8) {
      throw Exception('Recovery key must be at least 8 characters long.');
    }

    await ensureIdentityForCurrentUser();
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }

    final privateKeyB64 =
        await _secureStorage.read(key: '$_privateKeyPrefix$uid');
    final publicKeyB64 = await _secureStorage.read(key: '$_publicKeyPrefix$uid');

    if (privateKeyB64 == null ||
        privateKeyB64.isEmpty ||
        publicKeyB64 == null ||
        publicKeyB64.isEmpty) {
      throw Exception('Encrypted identity is not ready yet.');
    }

    Map<String, dynamic>? signalBackup;
    try {
      await _keyManagementService.ensureDeviceIdentity(userId: uid);
      signalBackup = await _keyManagementService.exportSignalBackupPayload();
    } catch (error) {
      debugPrint('[E2eeService] Signal backup export skipped: $error');
    }

    final payloadJson = jsonEncode({
      'version': _recoveryVersion,
      'algorithm': _algorithm,
      'privateKey': privateKeyB64,
      'publicKey': publicKeyB64,
      'signalBackup': signalBackup,
      'savedAt': DateTime.now().toUtc().toIso8601String(),
    });

    final salt = _randomBytes(16);
    final nonce = _randomBytes(12);
    final recoveryKey = await _deriveRecoverySecretKey(
      passphrase: trimmed,
      salt: salt,
    );
    final secretBox = await _cipher.encrypt(
      utf8.encode(payloadJson),
      secretKey: recoveryKey,
      nonce: nonce,
    );

    await _firestore.collection('users').doc(uid).set({
      'e2eeRecoveryEnabled': true,
      'e2eeRecoveryVersion': _recoveryVersion,
      'e2eeRecoveryAlgorithm': _recoveryAlgorithm,
      'e2eeRecoveryIterations': _recoveryIterations,
      'e2eeRecoverySalt': base64Encode(salt),
      'e2eeRecoveryNonce': base64Encode(secretBox.nonce),
      'e2eeRecoveryMac': base64Encode(secretBox.mac.bytes),
      'e2eeRecoveryCipherText': base64Encode(secretBox.cipherText),
      'e2eeRecoveryUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> restoreIdentityFromRecoveryKey({
    required String passphrase,
  }) async {
    final trimmed = passphrase.trim();
    if (trimmed.isEmpty) {
      throw Exception('Recovery key is required.');
    }

    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }

    final userDoc = await _firestore.collection('users').doc(uid).get();
    final data = userDoc.data() ?? <String, dynamic>{};
    final cipherTextB64 = data['e2eeRecoveryCipherText']?.toString() ?? '';
    final saltB64 = data['e2eeRecoverySalt']?.toString() ?? '';
    final nonceB64 = data['e2eeRecoveryNonce']?.toString() ?? '';
    final macB64 = data['e2eeRecoveryMac']?.toString() ?? '';

    if (cipherTextB64.isEmpty ||
        saltB64.isEmpty ||
        nonceB64.isEmpty ||
        macB64.isEmpty) {
      throw Exception('No recovery key backup was found for this account.');
    }

    final recoveryKey = await _deriveRecoverySecretKey(
      passphrase: trimmed,
      salt: base64Decode(saltB64),
    );
    final secretBox = SecretBox(
      base64Decode(cipherTextB64),
      nonce: base64Decode(nonceB64),
      mac: Mac(base64Decode(macB64)),
    );

    late final String privateKeyB64;
    late final String publicKeyB64;
    Map<String, dynamic>? signalBackup;
    try {
      final clearBytes = await _cipher.decrypt(
        secretBox,
        secretKey: recoveryKey,
      );
      final payload = jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
      privateKeyB64 = payload['privateKey']?.toString() ?? '';
      publicKeyB64 = payload['publicKey']?.toString() ?? '';
      final rawSignalBackup = payload['signalBackup'];
      if (rawSignalBackup is Map<String, dynamic>) {
        signalBackup = rawSignalBackup;
      } else if (rawSignalBackup is Map) {
        signalBackup = rawSignalBackup.map(
          (key, value) => MapEntry(key.toString(), value),
        );
      }
    } catch (_) {
      throw Exception('Recovery key is incorrect.');
    }

    if (privateKeyB64.isEmpty || publicKeyB64.isEmpty) {
      throw Exception('Recovery backup is incomplete.');
    }

    final existingRemotePublicKey = data['e2eePublicKey']?.toString().trim() ?? '';
    final previousPublicKeys =
        (data['e2eePreviousPublicKeys'] as List<dynamic>? ?? const <dynamic>[])
            .map((entry) => entry.toString())
            .where((value) => value.trim().isNotEmpty)
            .toSet();

    await _rememberCurrentLocalIdentity(
      uid: uid,
      replacingWithPublicKeyB64: publicKeyB64,
    );

    await _secureStorage.write(
      key: '$_privateKeyPrefix$uid',
      value: privateKeyB64,
    );
    await _secureStorage.write(
      key: '$_publicKeyPrefix$uid',
      value: publicKeyB64,
    );

    await _firestore.collection('users').doc(uid).set({
      'e2eeEnabled': true,
      'e2eeVersion': 1,
      'e2eeAlgorithm': _algorithm,
      'e2eePublicKey': publicKeyB64,
      'e2eePreviousPublicKeys': [
        ...{
          ...previousPublicKeys,
          if (existingRemotePublicKey.isNotEmpty &&
              existingRemotePublicKey != publicKeyB64)
            existingRemotePublicKey,
        },
      ],
      'e2eeRecoveryRestoredAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _cachedKeyPairUserId = null;
    _cachedCurrentUserKeyPair = null;
    _keyPairFuture = null;
    _ensuredUserId = null;
    _ensureIdentityFuture = null;
    _syncedRemoteIdentityUserId = null;
    _syncedRemoteIdentityPublicKey = null;
    _remoteIdentitySyncFuture = null;
    _publicKeyCache.clear();
    _publicKeyFutureCache.clear();
    _previousPublicKeysCache.clear();
    _previousPublicKeysFutureCache.clear();
    _conversationKeyCache.clear();
    _decryptedTextCache.clear();
    _sessionCache.clear();
    _cachedLocalKeyHistory = null;
    _cachedLocalKeyHistoryUserId = null;
    _peerRepairFutureCache.clear();
    _peerRepairTimestamps.clear();

    if (signalBackup != null) {
      try {
        await _keyManagementService.restoreSignalBackupPayload(signalBackup);
      } catch (error) {
        debugPrint('[E2eeService] Signal backup restore skipped: $error');
      }
    }

    await ensureIdentityForCurrentUser();
  }

  Future<bool> bootstrapAutomaticAccountBackup({
    required String accountPassword,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty || accountPassword.isEmpty) {
      return false;
    }

    await cacheAutomaticAccountBackupSecret(accountPassword: accountPassword);
    return resumeAutomaticAccountBootstrapIfPossible();
  }

  Future<void> cacheAutomaticAccountBackupSecret({
    required String accountPassword,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty || accountPassword.isEmpty) {
      return;
    }

    final derivedPassphrase = await _deriveAutomaticBackupPassphrase(
      uid: uid,
      accountPassword: accountPassword,
    );
    await _secureStorage.write(
      key: '$_accountBackupPassphrasePrefix$uid',
      value: derivedPassphrase,
    );
  }

  Future<bool> resumeAutomaticAccountBootstrapIfPossible() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      return false;
    }

    final passphrase = await _secureStorage.read(
      key: '$_accountBackupPassphrasePrefix$uid',
    );
    if (passphrase == null || passphrase.isEmpty) {
      return false;
    }

    final inFlight = _automaticBackupBootstrapFuture;
    if (inFlight != null) {
      return inFlight;
    }

    final future = _completeAutomaticAccountBootstrap(
      uid: uid,
      passphrase: passphrase,
    );

    _automaticBackupBootstrapFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_automaticBackupBootstrapFuture, future)) {
        _automaticBackupBootstrapFuture = null;
      }
    }
  }

  Future<void> bootstrapIfNeeded({
    String? accountPassword,
    bool syncRemote = true,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      return;
    }

    final trimmedPassword = accountPassword?.trim() ?? '';
    if (trimmedPassword.isNotEmpty) {
      await cacheAutomaticAccountBackupSecret(accountPassword: trimmedPassword);
    }

    final markerKey = '$_bootstrappedMarkerPrefix$uid';
    final alreadyBootstrapped = await _secureStorage.read(key: markerKey);
    final hasLocalIdentity = await _hasLocalIdentity(uid);

    if (alreadyBootstrapped == 'true' && hasLocalIdentity) {
      await ensureReady(syncRemote: syncRemote);
      if (trimmedPassword.isNotEmpty) {
        await syncAutomaticAccountBackupIfAvailable();
      }
      return;
    }

    await resumeAutomaticAccountBootstrapIfPossible();
    await ensureReady(syncRemote: syncRemote);
    if (trimmedPassword.isNotEmpty) {
      await syncAutomaticAccountBackupIfAvailable();
    }

    if (await _hasLocalIdentity(uid)) {
      await _secureStorage.write(key: markerKey, value: 'true');
    }
  }

  void scheduleAutomaticAccountBootstrap({
    required String accountPassword,
  }) {
    if (accountPassword.isEmpty) {
      return;
    }
    unawaited(() async {
      try {
        await bootstrapIfNeeded(accountPassword: accountPassword);
      } catch (error) {
        debugPrint('[E2eeService] Deferred automatic bootstrap failed: $error');
      }
    }());
  }

  void scheduleAutomaticAccountBootstrapIfPossible() {
    unawaited(() async {
      try {
        await bootstrapIfNeeded();
      } catch (error) {
        debugPrint('[E2eeService] Deferred stored-secret bootstrap failed: $error');
      }
    }());
  }

  Future<bool> _completeAutomaticAccountBootstrap({
    required String uid,
    required String passphrase,
  }) async {
    final hasLocalIdentity = await _hasLocalIdentity(uid);
    final hasRemoteBackup = await _hasRemoteRecoveryBackup(uid);
    if (!hasLocalIdentity && hasRemoteBackup) {
      try {
        await restoreIdentityFromRecoveryKey(passphrase: passphrase);
        await syncAutomaticAccountBackupIfAvailable();
        return true;
      } catch (error) {
        debugPrint('[E2eeService] Automatic backup restore failed: $error');
        return false;
      }
    }

    if (!hasLocalIdentity) {
      await ensureIdentityForCurrentUser(forceRepublish: true);
    }
    await syncAutomaticAccountBackupIfAvailable();
    return true;
  }

  Future<void> syncAutomaticAccountBackupIfAvailable() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      return;
    }

    final passphrase = await _secureStorage.read(
      key: '$_accountBackupPassphrasePrefix$uid',
    );
    if (passphrase == null || passphrase.isEmpty) {
      return;
    }

    final inFlight = _automaticBackupSyncFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      try {
        await ensureIdentityForCurrentUser(forceRepublish: false);
        await saveRecoveryKeyBackup(passphrase: passphrase);
      } catch (error) {
        debugPrint('[E2eeService] Automatic backup sync skipped: $error');
      }
    }();

    _automaticBackupSyncFuture = future;
    try {
      await future;
    } finally {
      if (identical(_automaticBackupSyncFuture, future)) {
        _automaticBackupSyncFuture = null;
      }
    }
  }

  Future<void> clearAutomaticAccountBackupSecret([String? userId]) async {
    final uid = (userId ?? currentUserId).trim();
    if (uid.isEmpty) {
      return;
    }
    await _secureStorage.delete(key: '$_accountBackupPassphrasePrefix$uid');
    await _secureStorage.delete(key: '$_bootstrappedMarkerPrefix$uid');
  }

  Future<void> ensureReady({
    bool syncRemote = true,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      return;
    }

    final inFlightBootstrap = _automaticBackupBootstrapFuture;
    if (inFlightBootstrap != null) {
      await inFlightBootstrap;
    } else {
      await resumeAutomaticAccountBootstrapIfPossible();
    }

    await ensureIdentityForCurrentUser(syncRemote: syncRemote);

    if (await _hasLocalIdentity(uid)) {
      await _secureStorage.write(
        key: '$_bootstrappedMarkerPrefix$uid',
        value: 'true',
      );
    }
  }

  bool isEncryptedTextMessage(Map<String, dynamic> data) {
    return data['type'] == 'text' &&
        data['e2ee'] == true &&
        (data['cipherText']?.toString().isNotEmpty ?? false);
  }

  Future<void> seedDecryptedTextCache({
    required String senderId,
    required String receiverId,
    required String plaintext,
    String? nonce,
    String? mac,
    String? cacheKey,
    String? clientMessageId,
  }) async {
    final trimmedText = plaintext.trim();
    if (senderId.trim().isEmpty ||
        receiverId.trim().isEmpty ||
        trimmedText.isEmpty) {
      return;
    }

    final explicitCacheKey = cacheKey?.trim() ?? '';
    if (explicitCacheKey.isNotEmpty) {
      _decryptedTextCache[explicitCacheKey] = plaintext;
      final userId = currentUserId;
      if (userId.isNotEmpty) {
        final conversationId = _chatId(senderId.trim(), receiverId.trim());
        await _signalRepository.seedPlaintextCache(
          cacheKey: explicitCacheKey,
          conversationId: conversationId,
          messageId: null,
          clientMessageId: clientMessageId,
          senderId: senderId.trim(),
          receiverId: receiverId.trim(),
          plaintext: plaintext,
          messageType: 'text',
        );
      }
      return;
    }

    final trimmedNonce = nonce?.trim() ?? '';
    final trimmedMac = mac?.trim() ?? '';
    if (trimmedNonce.isEmpty || trimmedMac.isEmpty) {
      return;
    }

    final legacyCacheKey = [
      senderId.trim(),
      receiverId.trim(),
      trimmedNonce,
      trimmedMac,
    ].join('|');
    _decryptedTextCache[legacyCacheKey] = plaintext;
    final userId = currentUserId;
    if (userId.isNotEmpty) {
      final conversationId = _chatId(senderId.trim(), receiverId.trim());
      await _signalRepository.seedPlaintextCache(
        cacheKey: legacyCacheKey,
        conversationId: conversationId,
        messageId: null,
        clientMessageId: clientMessageId,
        senderId: senderId.trim(),
        receiverId: receiverId.trim(),
        plaintext: plaintext,
        messageType: 'text',
      );
    }
  }

  Future<void> finalizeOutgoingTextProjection({
    required String senderId,
    required String receiverId,
    required String messageId,
    required String plaintext,
    String? clientMessageId,
    String? cacheKey,
    String? nonce,
    String? mac,
    String messageType = 'text',
    int? timestampMs,
  }) async {
    final trimmedText = plaintext.trim();
    if (senderId.trim().isEmpty ||
        receiverId.trim().isEmpty ||
        messageId.trim().isEmpty ||
        trimmedText.isEmpty) {
      return;
    }

    final explicitCacheKey = cacheKey?.trim() ?? '';
    if (explicitCacheKey.isNotEmpty) {
      await _signalRepository.finalizeOutgoingTextProjection(
        conversationId: _chatId(senderId.trim(), receiverId.trim()),
        messageId: messageId.trim(),
        clientMessageId: clientMessageId,
        cacheKey: explicitCacheKey,
        senderId: senderId.trim(),
        receiverId: receiverId.trim(),
        plaintext: trimmedText,
        messageType: messageType,
        timestampMs: timestampMs,
        algorithm: ChatEncryptionRepository.signalAlgorithm,
      );
      return;
    }

    await seedDecryptedTextCache(
      senderId: senderId,
      receiverId: receiverId,
      plaintext: plaintext,
      nonce: nonce,
      mac: mac,
      clientMessageId: clientMessageId,
    );
  }

  Future<void> cacheOutgoingMediaBytes({
    required String senderId,
    required String receiverId,
    required Uint8List bytes,
    String? messageId,
    String? clientMessageId,
    String? cacheKey,
    required String messageType,
    String? fileName,
  }) async {
    if (senderId.trim().isEmpty ||
        receiverId.trim().isEmpty ||
        bytes.isEmpty) {
      return;
    }

    await _signalRepository.cacheOutgoingMediaBytes(
      conversationId: _chatId(senderId.trim(), receiverId.trim()),
      messageId: messageId,
      clientMessageId: clientMessageId,
      cacheKey: cacheKey,
      senderId: senderId.trim(),
      receiverId: receiverId.trim(),
      bytes: bytes,
      messageType: messageType,
      fileName: fileName,
    );
  }

  Future<void> cacheIncomingMediaBytes({
    required String senderId,
    required String receiverId,
    required Uint8List bytes,
    String? messageId,
    String? clientMessageId,
    String? cacheKey,
    required String messageType,
    String? fileName,
  }) async {
    if (senderId.trim().isEmpty ||
        receiverId.trim().isEmpty ||
        bytes.isEmpty) {
      return;
    }

    await _signalRepository.cacheIncomingMediaBytes(
      conversationId: _chatId(senderId.trim(), receiverId.trim()),
      messageId: messageId,
      clientMessageId: clientMessageId,
      cacheKey: cacheKey,
      senderId: senderId.trim(),
      receiverId: receiverId.trim(),
      bytes: bytes,
      messageType: messageType,
      fileName: fileName,
    );
  }

  Future<Uint8List?> getCachedMediaBytes({
    String? cacheKey,
    String? clientMessageId,
    String? messageId,
    String? fileName,
  }) async {
    return _signalRepository.getCachedMediaBytes(
      cacheKey: cacheKey,
      clientMessageId: clientMessageId,
      messageId: messageId,
      fileName: fileName,
    );
  }

  String? getSeededDecryptedText(Map<String, dynamic> data) {
    final signalCacheKey = data['e2eeCacheKey']?.toString().trim() ?? '';
    if (signalCacheKey.isNotEmpty) {
      final signalCached = _signalRepository.peekCachedPlaintext(signalCacheKey);
      if (signalCached != null && signalCached.trim().isNotEmpty) {
        return signalCached;
      }
      final legacySignalCached = _decryptedTextCache[signalCacheKey];
      if (legacySignalCached != null && legacySignalCached.trim().isNotEmpty) {
        return legacySignalCached;
      }
    }

    final senderId = data['senderId']?.toString().trim() ?? '';
    final receiverId = data['receiverId']?.toString().trim() ?? '';
    final nonce = data['e2eeNonce']?.toString().trim() ?? '';
    final mac = data['e2eeMac']?.toString().trim() ?? '';
    if (senderId.isEmpty || receiverId.isEmpty || nonce.isEmpty || mac.isEmpty) {
      return null;
    }

    final cacheKey = [
      senderId,
      receiverId,
      nonce,
      mac,
    ].join('|');
    return _decryptedTextCache[cacheKey];
  }

  bool isUnavailablePlaceholder(String text) {
    final trimmed = text.trim();
    return trimmed.startsWith('[') && trimmed.endsWith(']');
  }

  Future<void> ensureIdentityForCurrentUser({
    bool forceRepublish = false,
    bool syncRemote = true,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;
    try {
      await _keyManagementService.ensureDeviceIdentity(
        userId: uid,
        forceRepublish: forceRepublish,
      );
    } catch (error) {
      debugPrint('[E2eeService] Signal identity bootstrap skipped: $error');
    }
    await _ensureLocalIdentityForCurrentUser(uid);
    if (!syncRemote) {
      return;
    }
    await _syncCurrentIdentityDocumentIfNeeded(
      uid: uid,
      forceRepublish: forceRepublish,
    );
  }

  Future<void> _ensureLocalIdentityForCurrentUser(String uid) async {
    _resetCachesIfUserChanged(uid);
    final inFlight = _ensureIdentityFuture;
    if (inFlight != null) {
      await inFlight;
      if (_ensuredUserId == uid) {
        return;
      }
    }
    if (_ensuredUserId == uid) {
      return;
    }

    final future = () async {
      final privateStorageKey = '$_privateKeyPrefix$uid';
      final publicStorageKey = '$_publicKeyPrefix$uid';

      var privateKeyB64 = await _secureStorage.read(key: privateStorageKey);
      var publicKeyB64 = await _secureStorage.read(key: publicStorageKey);

      if (privateKeyB64 == null ||
          privateKeyB64.isEmpty ||
          publicKeyB64 == null ||
          publicKeyB64.isEmpty) {
        final keyPair = await _keyExchange.newKeyPair();
        final simpleKeyPair = await keyPair.extract();

        privateKeyB64 = base64Encode(simpleKeyPair.bytes);
        publicKeyB64 = base64Encode(simpleKeyPair.publicKey.bytes);

        await _secureStorage.write(
          key: privateStorageKey,
          value: privateKeyB64,
        );
        await _secureStorage.write(
          key: publicStorageKey,
          value: publicKeyB64,
        );
      }

      _cachedCurrentUserKeyPair = SimpleKeyPairData(
        base64Decode(privateKeyB64),
        type: KeyPairType.x25519,
        publicKey: SimplePublicKey(
          base64Decode(publicKeyB64),
          type: KeyPairType.x25519,
        ),
      );
      _cachedKeyPairUserId = uid;
      _publicKeyCache[uid] = _cachedCurrentUserKeyPair!.publicKey;
      _ensuredUserId = uid;
    }();

    _ensureIdentityFuture = future;
    try {
      await future;
    } finally {
      if (identical(_ensureIdentityFuture, future)) {
        _ensureIdentityFuture = null;
      }
    }
  }

  Future<void> _syncCurrentIdentityDocumentIfNeeded({
    required String uid,
    required bool forceRepublish,
  }) async {
    final keyPair = await _readCurrentUserKeyPair();
    final publicKeyB64 = base64Encode(keyPair.publicKey.bytes);

    final inFlight = _remoteIdentitySyncFuture;
    if (inFlight != null) {
      await inFlight;
      if (_syncedRemoteIdentityUserId == uid &&
          _syncedRemoteIdentityPublicKey == publicKeyB64 &&
          !forceRepublish) {
        return;
      }
    }

    if (_syncedRemoteIdentityUserId == uid &&
        _syncedRemoteIdentityPublicKey == publicKeyB64 &&
        !forceRepublish) {
      return;
    }

    final future = () async {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final data = userDoc.data() ?? const <String, dynamic>{};
      final existingRemotePublicKey =
          data['e2eePublicKey']?.toString().trim() ?? '';
      final previousPublicKeys =
          (data['e2eePreviousPublicKeys'] as List<dynamic>? ??
                  const <dynamic>[])
              .map((entry) => entry.toString())
              .where((value) => value.trim().isNotEmpty)
              .toList();
      final alreadyPublished =
          existingRemotePublicKey == publicKeyB64 && data['e2eeEnabled'] == true;

      if (forceRepublish || !alreadyPublished) {
        await _publishIdentityDocument(
          uid: uid,
          publicKeyB64: publicKeyB64,
          existingRemotePublicKey: existingRemotePublicKey,
          previousPublicKeys: previousPublicKeys,
        );
      }

      _syncedRemoteIdentityUserId = uid;
      _syncedRemoteIdentityPublicKey = publicKeyB64;
    }();

    _remoteIdentitySyncFuture = future;
    try {
      await future;
    } finally {
      if (identical(_remoteIdentitySyncFuture, future)) {
        _remoteIdentitySyncFuture = null;
      }
    }
  }

  Future<void> _publishIdentityDocument({
    required String uid,
    required String publicKeyB64,
    required String existingRemotePublicKey,
    required Iterable<String> previousPublicKeys,
  }) async {
    await _firestore.collection('users').doc(uid).set({
      'e2eeEnabled': true,
      'e2eeVersion': 1,
      'e2eeAlgorithm': _algorithm,
      'e2eePublicKey': publicKeyB64,
      'e2eePreviousPublicKeys': [
        ...{
          ...previousPublicKeys,
          if (existingRemotePublicKey.isNotEmpty &&
              existingRemotePublicKey != publicKeyB64)
            existingRemotePublicKey,
        },
      ],
      'e2eeUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<EncryptedTextPayload> encryptTextForPeer({
    required String receiverId,
    required String plaintext,
  }) async {
    final envelope = await encryptTextEnvelope(
      receiverId: receiverId,
      plaintext: plaintext,
    );
    return EncryptedTextPayload(
      cipherText: envelope['cipherText']?.toString() ?? '',
      nonce: envelope['e2eeNonce']?.toString() ?? '',
      mac: envelope['e2eeMac']?.toString() ?? '',
      version: (envelope['e2eeVersion'] as num?)?.toInt() ?? 1,
      algorithm: envelope['e2eeAlgorithm']?.toString() ?? _algorithm,
    );
  }

  Future<EncryptedBinaryPayload> encryptBytesForPeer({
    required String receiverId,
    required List<int> bytes,
  }) async {
    final envelope = await encryptBinaryEnvelope(
      receiverId: receiverId,
      bytes: bytes,
    );
    return EncryptedBinaryPayload(
      cipherBytes: envelope['cipherBytes'] as Uint8List? ?? Uint8List(0),
      nonce: envelope['e2eeNonce']?.toString() ?? '',
      mac: envelope['e2eeMac']?.toString() ?? '',
      version: (envelope['e2eeVersion'] as num?)?.toInt() ?? 1,
      algorithm: envelope['e2eeAlgorithm']?.toString() ?? _algorithm,
    );
  }

  Future<String> decryptTextMessage(
    Map<String, dynamic> data, {
    bool allowRepair = false,
  }) async {
    final signalEnvelope = _signalRepository.isSignalEnvelope(data);
    final legacyEnvelope = isEncryptedTextMessage(data) && !signalEnvelope;

    if (signalEnvelope) {
      try {
        final plaintext = await _signalRepository.decryptTextMessage(
          data,
          allowRepair: allowRepair,
        );
        unawaited(syncAutomaticAccountBackupIfAvailable());
        return plaintext;
      } catch (error) {
        debugPrint('[E2eeService] Signal text decrypt fallback: $error');
        return '[Encrypted message unavailable]';
      }
    }

    if (legacyEnvelope) {
      return _decryptTextMessageLegacy(
        data,
        allowRepair: allowRepair,
      );
    }

    final clearText = data['text']?.toString() ?? '';
    final looksEncrypted =
        data['e2ee'] == true ||
        (data['cipherText']?.toString().isNotEmpty ?? false);
    if (looksEncrypted && clearText.trim().isEmpty) {
      return '[Encrypted message unavailable]';
    }
    return clearText;
  }

  Future<String> _decryptTextMessageLegacy(
    Map<String, dynamic> data, {
    bool allowRepair = false,
  }) async {

    final legacyText = data['text']?.toString() ?? '';
    if (!isEncryptedTextMessage(data)) {
      return legacyText;
    }

    final uid = currentUserId;
    if (uid.isEmpty) {
      return '[Encrypted message unavailable]';
    }

    await ensureIdentityForCurrentUser(syncRemote: false);

    final senderId = data['senderId']?.toString() ?? '';
    final receiverId = data['receiverId']?.toString() ?? '';
    final peerId = senderId == uid ? receiverId : senderId;
    if (peerId.isEmpty) {
      return legacyText.isNotEmpty
          ? legacyText
          : '[Encrypted message unavailable]';
    }
    final cacheKey = [
      senderId,
      receiverId,
      data['e2eeNonce']?.toString() ?? '',
      data['e2eeMac']?.toString() ?? '',
    ].join('|');
    final cachedText = _decryptedTextCache[cacheKey];
    if (cachedText != null) return cachedText;

    final clearText = await _tryDecryptTextWithCurrentCandidates(
      data: data,
      uid: uid,
      senderId: senderId,
      peerId: peerId,
      cacheKey: cacheKey,
    );
    if (clearText != null) {
      return clearText;
    }

    if (allowRepair && _shouldAttemptAutoRepair(data)) {
      await _repairConversationStateForPeer(peerId);
      final repairedText = await _tryDecryptTextWithCurrentCandidates(
        data: data,
        uid: uid,
        senderId: senderId,
        peerId: peerId,
        cacheKey: cacheKey,
        forceRefreshPeer: true,
      );
      if (repairedText != null) {
        return repairedText;
      }
    }

    return legacyText.isNotEmpty
        ? legacyText
        : '[Encrypted message from previous key unavailable]';
  }

  Future<void> prewarmConversation(String otherUserId) async {
    if (otherUserId.trim().isEmpty) return;
    try {
      await _signalRepository.prewarmConversation(otherUserId);
      return;
    } catch (error) {
      debugPrint('[E2eeService] Signal prewarm fallback: $error');
    }

    await ensureIdentityForCurrentUser(syncRemote: false);
    final keyPair = await _readCurrentUserKeyPair();
    final peerPublicKey = await _readUserPublicKey(otherUserId);
    if (peerPublicKey == null) return;
    await _deriveConversationKey(
      keyPair: keyPair,
      peerPublicKey: peerPublicKey,
      otherUserId: otherUserId,
    );
  }

  Future<String?> _tryDecryptTextWithCurrentCandidates({
    required Map<String, dynamic> data,
    required String uid,
    required String senderId,
    required String peerId,
    required String cacheKey,
    bool forceRefreshPeer = false,
  }) async {
    final localKeyPairs = await _resolveLocalKeyPairsForMessage(
      data: data,
      senderId: senderId,
    );
    final peerPublicKeys = await _resolvePeerPublicKeysForMessage(
      data: data,
      peerId: peerId,
      senderId: senderId,
      forceRefreshLive: forceRefreshPeer,
    );
    if (localKeyPairs.isEmpty ||
        (peerPublicKeys.exact.isEmpty && peerPublicKeys.fallback.isEmpty)) {
      return null;
    }

    final cipherText = base64Decode(data['cipherText'].toString());
    final nonce = base64Decode(data['e2eeNonce'].toString());
    final mac = base64Decode(data['e2eeMac'].toString());
    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: Mac(mac),
    );
    final chatId = _chatId(uid, peerId);

    for (final peerGroup in <List<SimplePublicKey>>[
      peerPublicKeys.exact,
      peerPublicKeys.fallback,
    ]) {
      for (final localKeyPair in localKeyPairs) {
        for (final peerPublicKey in peerGroup) {
          final derivationKeys = _buildConversationDerivationKeys(
            chatId: chatId,
            localPublicKeyBase64: base64Encode(localKeyPair.publicKey.bytes),
            peerPublicKeyBase64: base64Encode(peerPublicKey.bytes),
          );
          for (final derivationKey in derivationKeys) {
            try {
              final conversationKey = await _deriveConversationKey(
                keyPair: localKeyPair,
                peerPublicKey: peerPublicKey,
                otherUserId: peerId,
                derivationKeyOverride: derivationKey,
              );

              final clearBytes = await _cipher.decrypt(
                secretBox,
                secretKey: conversationKey,
              );
              final clearText = utf8.decode(clearBytes);
              _decryptedTextCache[cacheKey] = clearText;
              return clearText;
            } catch (_) {
              continue;
            }
          }
        }
      }
    }

    return null;
  }

  Future<Uint8List?> _tryDecryptBytesWithCurrentCandidates({
    required Map<String, dynamic> data,
    required String uid,
    required String senderId,
    required String peerId,
    required List<int> cipherBytes,
    bool forceRefreshPeer = false,
  }) async {
    final localKeyPairs = await _resolveLocalKeyPairsForMessage(
      data: data,
      senderId: senderId,
    );
    final peerPublicKeys = await _resolvePeerPublicKeysForMessage(
      data: data,
      peerId: peerId,
      senderId: senderId,
      forceRefreshLive: forceRefreshPeer,
    );
    if (localKeyPairs.isEmpty ||
        (peerPublicKeys.exact.isEmpty && peerPublicKeys.fallback.isEmpty)) {
      return null;
    }

    final nonce = base64Decode(data['e2eeNonce'].toString());
    final mac = base64Decode(data['e2eeMac'].toString());
    final secretBox = SecretBox(
      cipherBytes,
      nonce: nonce,
      mac: Mac(mac),
    );
    final chatId = _chatId(uid, peerId);

    for (final peerGroup in <List<SimplePublicKey>>[
      peerPublicKeys.exact,
      peerPublicKeys.fallback,
    ]) {
      for (final localKeyPair in localKeyPairs) {
        for (final peerPublicKey in peerGroup) {
          final derivationKeys = _buildConversationDerivationKeys(
            chatId: chatId,
            localPublicKeyBase64: base64Encode(localKeyPair.publicKey.bytes),
            peerPublicKeyBase64: base64Encode(peerPublicKey.bytes),
          );
          for (final derivationKey in derivationKeys) {
            try {
              final conversationKey = await _deriveConversationKey(
                keyPair: localKeyPair,
                peerPublicKey: peerPublicKey,
                otherUserId: peerId,
                derivationKeyOverride: derivationKey,
              );

              final clearBytes = await _cipher.decrypt(
                secretBox,
                secretKey: conversationKey,
              );
              return Uint8List.fromList(clearBytes);
            } catch (_) {
              continue;
            }
          }
        }
      }
    }

    return null;
  }

  Future<void> _repairConversationStateForPeer(String peerId) async {
    final trimmedPeerId = peerId.trim();
    if (trimmedPeerId.isEmpty) return;

    final uid = currentUserId;
    if (uid.isEmpty) return;

    final existing = _peerRepairFutureCache[trimmedPeerId];
    if (existing != null) {
      await existing;
      return;
    }

    final lastRepair = _peerRepairTimestamps[trimmedPeerId];
    if (lastRepair != null &&
        DateTime.now().difference(lastRepair) < _repairCooldown) {
      return;
    }

    final future = () async {
      final chatId = _chatId(uid, trimmedPeerId);
      _conversationKeyCache.removeWhere((key, _) => key.startsWith('$chatId|'));
      _sessionCache.removeWhere(
        (_, session) =>
            session.chatId == chatId || session.peerId == trimmedPeerId,
      );
      _publicKeyCache.remove(trimmedPeerId);
      _publicKeyFutureCache.remove(trimmedPeerId);
      _previousPublicKeysCache.remove(trimmedPeerId);
      _previousPublicKeysFutureCache.remove(trimmedPeerId);

      await ensureIdentityForCurrentUser(syncRemote: false);
      await _syncCurrentIdentityDocumentIfNeeded(
        uid: uid,
        forceRepublish: true,
      );
      await _readUserPublicKey(trimmedPeerId, forceRefresh: true);
      await _readUserPreviousPublicKeys(trimmedPeerId, forceRefresh: true);
      await prewarmConversation(trimmedPeerId);
      _peerRepairTimestamps[trimmedPeerId] = DateTime.now();
    }();

    _peerRepairFutureCache[trimmedPeerId] = future;
    try {
      await future;
    } finally {
      _peerRepairFutureCache.remove(trimmedPeerId);
    }
  }

  bool _shouldAttemptAutoRepair(Map<String, dynamic> data) {
    final timestamp = _extractMessageTime(data['timestamp']);
    if (timestamp == null) {
      return false;
    }

    final now = DateTime.now();
    final age = now.isAfter(timestamp)
        ? now.difference(timestamp)
        : timestamp.difference(now);
    return age <= _autoRepairFreshWindow;
  }

  DateTime? _extractMessageTime(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }

  Future<List<SimpleKeyPairData>> _resolveLocalKeyPairsForMessage({
    required Map<String, dynamic> data,
    required String senderId,
  }) async {
    final currentKeyPair = await _readCurrentUserKeyPair();
    final historyKeyPairs = await _readLocalKeyHistory();
    final byPublicKey = <String, SimpleKeyPairData>{};

    void addKeyPair(SimpleKeyPairData keyPair) {
      final publicKeyB64 = base64Encode(keyPair.publicKey.bytes);
      byPublicKey.putIfAbsent(publicKeyB64, () => keyPair);
    }

    addKeyPair(currentKeyPair);
    for (final keyPair in historyKeyPairs) {
      addKeyPair(keyPair);
    }

    final ordered = <SimpleKeyPairData>[];
    final used = <String>{};

    void addMatching(String? publicKeyB64) {
      final trimmed = publicKeyB64?.trim() ?? '';
      if (trimmed.isEmpty) return;
      final keyPair = byPublicKey[trimmed];
      if (keyPair == null || !used.add(trimmed)) return;
      ordered.add(keyPair);
    }

    for (final exactLocalKey in _exactLocalPublicKeyCandidates(
      data: data,
      senderId: senderId,
    )) {
      addMatching(exactLocalKey);
    }

    addMatching(base64Encode(currentKeyPair.publicKey.bytes));

    for (final entry in byPublicKey.entries) {
      if (!used.add(entry.key)) continue;
      ordered.add(entry.value);
    }

    return ordered;
  }

  Future<_PeerPublicKeyCandidates> _resolvePeerPublicKeysForMessage({
    required Map<String, dynamic> data,
    required String peerId,
    required String senderId,
    bool forceRefreshLive = false,
  }) async {
    final exact = <SimplePublicKey>[];
    final fallback = <SimplePublicKey>[];
    final seen = <String>{};

    void addKeyBytes(List<SimplePublicKey> target, List<int>? bytes) {
      if (bytes == null || bytes.isEmpty) return;
      final encoded = base64Encode(bytes);
      if (!seen.add(encoded)) return;
      target.add(SimplePublicKey(bytes, type: KeyPairType.x25519));
    }

    void addKeyB64(List<SimplePublicKey> target, String? value) {
      final trimmed = value?.trim() ?? '';
      if (trimmed.isEmpty) return;
      try {
        addKeyBytes(target, base64Decode(trimmed));
      } catch (_) {
        return;
      }
    }

    for (final exactPeerKey in _exactPeerPublicKeyCandidates(
      data: data,
      senderId: senderId,
    )) {
      addKeyB64(exact, exactPeerKey);
    }

    final liveKey = await _readUserPublicKey(
      peerId,
      forceRefresh: forceRefreshLive,
    );
    if (liveKey != null) {
      addKeyBytes(fallback, liveKey.bytes);
    }

    final previousKeys = await _readUserPreviousPublicKeys(
      peerId,
      forceRefresh: forceRefreshLive,
    );
    for (final key in previousKeys) {
      addKeyBytes(fallback, key.bytes);
    }

    return _PeerPublicKeyCandidates(exact: exact, fallback: fallback);
  }

  Future<Uint8List> decryptBytesMessage({
    required Map<String, dynamic> data,
    required List<int> cipherBytes,
    bool allowRepair = false,
  }) async {
    if (_signalRepository.isSignalEnvelope(data)) {
      try {
        final clearBytes = await _signalRepository.decryptBytesMessage(
          data: data,
          cipherBytes: cipherBytes,
          allowRepair: allowRepair,
        );
        unawaited(syncAutomaticAccountBackupIfAvailable());
        return clearBytes;
      } catch (error) {
        debugPrint('[E2eeService] Signal media decrypt fallback: $error');
      }
    }

    return _decryptBytesMessageLegacy(
      data: data,
      cipherBytes: cipherBytes,
      allowRepair: allowRepair,
    );
  }

  Future<Uint8List> _decryptBytesMessageLegacy({
    required Map<String, dynamic> data,
    required List<int> cipherBytes,
    bool allowRepair = false,
  }) async {

    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }

    await ensureIdentityForCurrentUser(syncRemote: false);

    final senderId = data['senderId']?.toString() ?? '';
    final receiverId = data['receiverId']?.toString() ?? '';
    final peerId = senderId == uid ? receiverId : senderId;
    if (peerId.isEmpty) {
      throw Exception('Encrypted media peer is missing.');
    }

    final clearBytes = await _tryDecryptBytesWithCurrentCandidates(
      data: data,
      uid: uid,
      senderId: senderId,
      peerId: peerId,
      cipherBytes: cipherBytes,
    );
    if (clearBytes != null) {
      return clearBytes;
    }

    if (allowRepair && _shouldAttemptAutoRepair(data)) {
      await _repairConversationStateForPeer(peerId);
      final repairedBytes = await _tryDecryptBytesWithCurrentCandidates(
        data: data,
        uid: uid,
        senderId: senderId,
        peerId: peerId,
        cipherBytes: cipherBytes,
        forceRefreshPeer: true,
      );
      if (repairedBytes != null) {
        return repairedBytes;
      }
    }

    throw Exception('Encrypted media key is unavailable.');
  }

  Future<SimpleKeyPairData> _readCurrentUserKeyPair() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    _resetCachesIfUserChanged(uid);
    if (_cachedCurrentUserKeyPair != null && _cachedKeyPairUserId == uid) {
      return _cachedCurrentUserKeyPair!;
    }
    if (_keyPairFuture != null) {
      return _keyPairFuture!;
    }

    _keyPairFuture = () async {
      final privateKeyB64 =
          await _secureStorage.read(key: '$_privateKeyPrefix$uid');
      final publicKeyB64 =
          await _secureStorage.read(key: '$_publicKeyPrefix$uid');

      if (privateKeyB64 == null ||
          privateKeyB64.isEmpty ||
          publicKeyB64 == null ||
          publicKeyB64.isEmpty) {
        throw Exception('Encrypted identity is not ready.');
      }

      _cachedCurrentUserKeyPair = SimpleKeyPairData(
        base64Decode(privateKeyB64),
        type: KeyPairType.x25519,
        publicKey: SimplePublicKey(
          base64Decode(publicKeyB64),
          type: KeyPairType.x25519,
        ),
      );
      _cachedKeyPairUserId = uid;
      _publicKeyCache[uid] = _cachedCurrentUserKeyPair!.publicKey;
      return _cachedCurrentUserKeyPair!;
    }();

    try {
      return await _keyPairFuture!;
    } finally {
      _keyPairFuture = null;
    }
  }

  Future<void> _rememberCurrentLocalIdentity({
    required String uid,
    required String replacingWithPublicKeyB64,
  }) async {
    final currentPrivateKeyB64 =
        await _secureStorage.read(key: '$_privateKeyPrefix$uid');
    final currentPublicKeyB64 =
        await _secureStorage.read(key: '$_publicKeyPrefix$uid');
    if (currentPrivateKeyB64 == null ||
        currentPrivateKeyB64.isEmpty ||
        currentPublicKeyB64 == null ||
        currentPublicKeyB64.isEmpty ||
        currentPublicKeyB64 == replacingWithPublicKeyB64) {
      return;
    }

    await _appendLocalKeyHistory(
      uid: uid,
      privateKeyB64: currentPrivateKeyB64,
      publicKeyB64: currentPublicKeyB64,
    );
  }

  Future<void> _appendLocalKeyHistory({
    required String uid,
    required String privateKeyB64,
    required String publicKeyB64,
  }) async {
    if (uid.isEmpty ||
        privateKeyB64.trim().isEmpty ||
        publicKeyB64.trim().isEmpty) {
      return;
    }

    final storageKey = '$_localKeyHistoryPrefix$uid';
    final raw = await _secureStorage.read(key: storageKey);
    List<dynamic> decoded = const <dynamic>[];
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(raw) as List<dynamic>;
      } catch (_) {
        decoded = const <dynamic>[];
      }
    }

    final entries = <Map<String, String>>[
      <String, String>{
        'privateKey': privateKeyB64,
        'publicKey': publicKeyB64,
      },
    ];

    for (final entry in decoded) {
      if (entry is! Map) continue;
      final privateKey = entry['privateKey']?.toString() ?? '';
      final publicKey = entry['publicKey']?.toString() ?? '';
      if (privateKey.isEmpty || publicKey.isEmpty || publicKey == publicKeyB64) {
        continue;
      }
      entries.add(<String, String>{
        'privateKey': privateKey,
        'publicKey': publicKey,
      });
      if (entries.length >= _maxStoredLocalKeyHistoryEntries) {
        break;
      }
    }

    await _secureStorage.write(
      key: storageKey,
      value: jsonEncode(entries),
    );
    _cachedLocalKeyHistoryUserId = uid;
    _cachedLocalKeyHistory = null;
  }

  Future<List<SimpleKeyPairData>> _readLocalKeyHistory() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      return const <SimpleKeyPairData>[];
    }

    if (_cachedLocalKeyHistoryUserId == uid && _cachedLocalKeyHistory != null) {
      return _cachedLocalKeyHistory!;
    }

    final raw = await _secureStorage.read(key: '$_localKeyHistoryPrefix$uid');
    if (raw == null || raw.trim().isEmpty) {
      _cachedLocalKeyHistoryUserId = uid;
      _cachedLocalKeyHistory = const <SimpleKeyPairData>[];
      return const <SimpleKeyPairData>[];
    }

    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      final history = <SimpleKeyPairData>[];
      for (final entry in decoded) {
        if (entry is! Map) continue;
        final privateKeyB64 = entry['privateKey']?.toString() ?? '';
        final publicKeyB64 = entry['publicKey']?.toString() ?? '';
        if (privateKeyB64.isEmpty || publicKeyB64.isEmpty) {
          continue;
        }
        history.add(
          SimpleKeyPairData(
            base64Decode(privateKeyB64),
            type: KeyPairType.x25519,
            publicKey: SimplePublicKey(
              base64Decode(publicKeyB64),
              type: KeyPairType.x25519,
            ),
          ),
        );
      }
      _cachedLocalKeyHistoryUserId = uid;
      _cachedLocalKeyHistory = history;
      return history;
    } catch (_) {
      _cachedLocalKeyHistoryUserId = uid;
      _cachedLocalKeyHistory = const <SimpleKeyPairData>[];
      return const <SimpleKeyPairData>[];
    }
  }

  Future<List<SimplePublicKey>> _readUserPreviousPublicKeys(
    String uid, {
    bool forceRefresh = false,
  }) async {
    if (uid.isEmpty) {
      return const <SimplePublicKey>[];
    }

    if (!forceRefresh) {
      final cached = _previousPublicKeysCache[uid];
      if (cached != null) {
        return cached;
      }
      final inFlight = _previousPublicKeysFutureCache[uid];
      if (inFlight != null) {
        return inFlight;
      }
    } else {
      _previousPublicKeysCache.remove(uid);
      _previousPublicKeysFutureCache.remove(uid);
    }

    final future = () async {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final previousKeys =
          (userDoc.data()?['e2eePreviousPublicKeys'] as List<dynamic>? ??
                  const <dynamic>[])
              .map((entry) => entry.toString())
              .where((entry) => entry.trim().isNotEmpty)
              .toList(growable: false);
      final keys = <SimplePublicKey>[];
      final seen = <String>{};
      for (final key in previousKeys) {
        try {
          final bytes = base64Decode(key);
          final encoded = base64Encode(bytes);
          if (!seen.add(encoded)) {
            continue;
          }
          keys.add(SimplePublicKey(bytes, type: KeyPairType.x25519));
        } catch (_) {
          continue;
        }
      }
      _previousPublicKeysCache[uid] = keys;
      return keys;
    }();

    _previousPublicKeysFutureCache[uid] = future;
    try {
      return await future;
    } finally {
      _previousPublicKeysFutureCache.remove(uid);
    }
  }

  List<String> _exactLocalPublicKeyCandidates({
    required Map<String, dynamic> data,
    required String senderId,
  }) {
    final isSender = senderId == currentUserId;
    return _orderedUniquePublicKeyStrings(<String?>[
      if (isSender)
        data['e2eeSessionLocalPublicKey']?.toString()
      else
        data['e2eeSessionPeerPublicKey']?.toString(),
      if (isSender)
        data['senderPublicKey']?.toString()
      else
        data['receiverPublicKey']?.toString(),
    ]);
  }

  List<String> _exactPeerPublicKeyCandidates({
    required Map<String, dynamic> data,
    required String senderId,
  }) {
    final isSender = senderId == currentUserId;
    return _orderedUniquePublicKeyStrings(<String?>[
      if (isSender)
        data['e2eeSessionPeerPublicKey']?.toString()
      else
        data['e2eeSessionLocalPublicKey']?.toString(),
      if (isSender)
        data['receiverPublicKey']?.toString()
      else
        data['senderPublicKey']?.toString(),
    ]);
  }

  List<String> _orderedUniquePublicKeyStrings(List<String?> rawValues) {
    final seen = <String>{};
    final values = <String>[];
    for (final raw in rawValues) {
      final trimmed = raw?.trim() ?? '';
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      values.add(trimmed);
    }
    return values;
  }

  Future<SimplePublicKey?> _readUserPublicKey(
    String uid, {
    bool forceRefresh = false,
  }) async {
    if (uid.isEmpty) return null;
    final currentUid = currentUserId;
    if (currentUid.isNotEmpty) {
      _resetCachesIfUserChanged(currentUid);
    }

    if (!forceRefresh) {
      final cached = _publicKeyCache[uid];
      if (cached != null) return cached;
      final inFlight = _publicKeyFutureCache[uid];
      if (inFlight != null) return inFlight;
    } else {
      _publicKeyCache.remove(uid);
      _publicKeyFutureCache.remove(uid);
    }

    if (uid == currentUserId) {
      final localPublicB64 =
          await _secureStorage.read(key: '$_publicKeyPrefix$uid');
      if (localPublicB64 != null && localPublicB64.isNotEmpty) {
        final localKey = SimplePublicKey(
          base64Decode(localPublicB64),
          type: KeyPairType.x25519,
        );
        _publicKeyCache[uid] = localKey;
        return localKey;
      }
    }

    final future = () async {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final publicKeyB64 = userDoc.data()?['e2eePublicKey']?.toString() ?? '';
      if (publicKeyB64.isEmpty) return null;

      final publicKey = SimplePublicKey(
        base64Decode(publicKeyB64),
        type: KeyPairType.x25519,
      );
      _publicKeyCache[uid] = publicKey;
      return publicKey;
    }();

    _publicKeyFutureCache[uid] = future;
    try {
      return await future;
    } finally {
      _publicKeyFutureCache.remove(uid);
    }
  }

  Future<SecretKey> _deriveConversationKey({
    required SimpleKeyPairData keyPair,
    required SimplePublicKey peerPublicKey,
    required String otherUserId,
    String? derivationKeyOverride,
  }) async {
    final localPublicKeyB64 = base64Encode(keyPair.publicKey.bytes);
    final peerPublicKeyB64 = base64Encode(peerPublicKey.bytes);
    final chatId = _chatId(currentUserId, otherUserId);
    final cacheKey = derivationKeyOverride ??
        _buildSymmetricConversationDerivationKey(
          chatId: chatId,
          localPublicKeyBase64: localPublicKeyB64,
          peerPublicKeyBase64: peerPublicKeyB64,
        );
    final cached = _conversationKeyCache[cacheKey];
    if (cached != null) return cached;

    final sharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: peerPublicKey,
    );

    final derivedKey = await _hkdf.deriveKey(
      secretKey: sharedSecret,
      nonce: utf8.encode(cacheKey),
      info: utf8.encode('smishing_shield_ph:$_algorithm'),
    );
    _conversationKeyCache[cacheKey] = derivedKey;
    return derivedKey;
  }

  String _chatId(String userA, String userB) {
    final ids = [userA, userB]..sort();
    return ids.join('_');
  }

  String _buildSessionCacheKey({
    required String chatId,
    required String localPublicKeyBase64,
    required String peerPublicKeyBase64,
  }) {
    return '$chatId|$localPublicKeyBase64|$peerPublicKeyBase64';
  }

  String _buildSymmetricConversationDerivationKey({
    required String chatId,
    required String localPublicKeyBase64,
    required String peerPublicKeyBase64,
  }) {
    final ordered = <String>[
      localPublicKeyBase64.trim(),
      peerPublicKeyBase64.trim(),
    ]..sort();
    return '$chatId|${ordered.first}|${ordered.last}';
  }

  List<String> _buildConversationDerivationKeys({
    required String chatId,
    required String localPublicKeyBase64,
    required String peerPublicKeyBase64,
  }) {
    final candidates = <String>[
      _buildSymmetricConversationDerivationKey(
        chatId: chatId,
        localPublicKeyBase64: localPublicKeyBase64,
        peerPublicKeyBase64: peerPublicKeyBase64,
      ),
      '$chatId|$localPublicKeyBase64|$peerPublicKeyBase64',
      '$chatId|$peerPublicKeyBase64|$localPublicKeyBase64',
    ];
    final seen = <String>{};
    return candidates.where(seen.add).toList(growable: false);
  }

  String _buildSessionId({
    required String chatId,
    required String localPublicKeyBase64,
    required String peerPublicKeyBase64,
  }) {
    final normalizedKeys = <String>[
      localPublicKeyBase64.trim(),
      peerPublicKeyBase64.trim(),
    ]..sort();
    final keyA = _shortKeyFingerprint(normalizedKeys.first);
    final keyB = _shortKeyFingerprint(normalizedKeys.last);
    return '${chatId}_$keyA$keyB';
  }

  String _shortKeyFingerprint(String base64Key) {
    final normalized = base64Key
        .replaceAll('=', '')
        .replaceAll('+', '-')
        .replaceAll('/', '_');
    final safe = normalized.isEmpty ? 'unknown' : normalized;
    return safe.substring(0, min(16, safe.length));
  }

  Future<void> _persistSessionSnapshot(E2eeSessionContext session) async {
    final uid = currentUserId;
    if (uid.isEmpty) return;

    await _firestore
        .collection('users')
        .doc(uid)
        .collection('e2ee_sessions')
        .doc(session.sessionId)
        .set({
      'peerId': session.peerId,
      'chatId': session.chatId,
      'sessionId': session.sessionId,
      'algorithm': session.algorithm,
      'sessionVersion': session.sessionVersion,
      'localPublicKey': session.localPublicKeyBase64,
      'peerPublicKey': session.peerPublicKeyBase64,
      'keyType': 'static_x25519',
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  List<int> _randomBytes(int length) {
    return List<int>.generate(length, (_) => _random.nextInt(256));
  }

  Future<SecretKey> _deriveRecoverySecretKey({
    required String passphrase,
    required List<int> salt,
  }) {
    return _pbkdf2.deriveKeyFromPassword(
      password: passphrase,
      nonce: salt,
    );
  }

  Future<String> _deriveAutomaticBackupPassphrase({
    required String uid,
    required String accountPassword,
  }) async {
    final derivedKey = await _deriveRecoverySecretKey(
      passphrase: accountPassword,
      salt: utf8.encode('smishing_account_backup::$uid'),
    );
    final derivedBytes = await derivedKey.extractBytes();
    return base64UrlEncode(derivedBytes);
  }

  Future<bool> _hasLocalIdentity(String uid) async {
    final privateKeyB64 =
        await _secureStorage.read(key: '$_privateKeyPrefix$uid');
    final publicKeyB64 =
        await _secureStorage.read(key: '$_publicKeyPrefix$uid');
    final hasLegacyIdentity = privateKeyB64 != null &&
        privateKeyB64.isNotEmpty &&
        publicKeyB64 != null &&
        publicKeyB64.isNotEmpty;
    if (hasLegacyIdentity) {
      return true;
    }

    try {
      await _keyManagementService.initialize();
      final store = await _keyManagementService.getStore(uid);
      final deviceDocId = await store.getDeviceDocId();
      return deviceDocId.trim().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _hasRemoteRecoveryBackup(String uid) async {
    final userDoc = await _firestore.collection('users').doc(uid).get();
    final data = userDoc.data() ?? const <String, dynamic>{};
    final cipherTextB64 = data['e2eeRecoveryCipherText']?.toString() ?? '';
    final saltB64 = data['e2eeRecoverySalt']?.toString() ?? '';
    final nonceB64 = data['e2eeRecoveryNonce']?.toString() ?? '';
    final macB64 = data['e2eeRecoveryMac']?.toString() ?? '';
    return cipherTextB64.isNotEmpty &&
        saltB64.isNotEmpty &&
        nonceB64.isNotEmpty &&
        macB64.isNotEmpty;
  }

  void _resetCachesIfUserChanged(String uid) {
    if (_cachedKeyPairUserId == null || _cachedKeyPairUserId == uid) return;
    _cachedKeyPairUserId = null;
    _cachedCurrentUserKeyPair = null;
    _keyPairFuture = null;
    _ensuredUserId = null;
    _ensureIdentityFuture = null;
    _syncedRemoteIdentityUserId = null;
    _syncedRemoteIdentityPublicKey = null;
    _remoteIdentitySyncFuture = null;
    _publicKeyCache.clear();
    _publicKeyFutureCache.clear();
    _previousPublicKeysCache.clear();
    _previousPublicKeysFutureCache.clear();
    _conversationKeyCache.clear();
    _decryptedTextCache.clear();
    _sessionCache.clear();
    _cachedLocalKeyHistory = null;
    _cachedLocalKeyHistoryUserId = null;
    _peerRepairFutureCache.clear();
    _peerRepairTimestamps.clear();
    _automaticBackupBootstrapFuture = null;
  }
}
