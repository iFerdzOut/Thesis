import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cryptography/cryptography.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'local_message_cache_service.dart';
import 'chat_encryption_repository.dart';
import 'security_service.dart';

class E2eeService {
  E2eeService._internal();

  static final E2eeService _instance = E2eeService._internal();
  factory E2eeService() => _instance;

  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  static const String _bootstrappedMarkerPrefix = 'e2ee_bootstrapped_v1_';
  static const String _zeroKnowledgePassphrasePrefix =
      'e2ee_zero_knowledge_passphrase_';
  static const String _accountBackupPassphrasePrefix =
      'e2ee_account_backup_passphrase_';
  static const String _algorithm = 'rsa-aes-cbc-v1';
  static const String _recoveryAlgorithm = 'pbkdf2-aesgcm-v1';
  static const int _recoveryVersion = 1;
  static const int _recoveryIterations = 150000;

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final LocalMessageCacheService _localCache = LocalMessageCacheService();
  final ChatEncryptionRepository _chatEncryptionRepository =
      ChatEncryptionRepository();
  final AesGcm _cipher = AesGcm.with256bits();
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
  RSAKeyPairData? _cachedCurrentUserKeyPair;
  Future<RSAKeyPairData>? _keyPairFuture;
  final Map<String, String> _publicKeyCache = <String, String>{};
  final Map<String, Future<String?>> _publicKeyFutureCache =
      <String, Future<String?>>{};
  Future<void>? _automaticBackupSyncFuture;
  Future<bool>? _automaticBackupBootstrapFuture;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _onlineChatHydrationSubscription;
  String? _onlineChatHydrationUserId;
  Future<void>? _onlineChatInitialHydrationFuture;
  String? _onlineChatInitialHydrationUserId;
  final Set<String> _onlineChatSeenLatestMessageKeys = <String>{};

  String get currentUserId => _auth.currentUser?.uid ?? '';

  Future<bool> hasLocalIdentity() async {
    return await _hasLocalIdentity(currentUserId);
  }

  Future<bool> hasRemoteBackup() async {
    return await _hasRemoteRecoveryBackup(currentUserId);
  }

  Future<RemoteBackupStatus> getRemoteBackupStatus() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      return const RemoteBackupStatus.none();
    }

    final userDoc = await _firestore
        .collection('users')
        .doc(uid)
        .get(const GetOptions(source: Source.server));
    final data = userDoc.data() ?? const <String, dynamic>{};
    final hasRecoveryPayload = _hasRecoveryPayload(data);
    final hasPinMetadata = data['zkPinEnabled'] == true ||
        (data['zkPinSalt']?.toString().trim().isNotEmpty ?? false) ||
        (data['zkMasterKeyCipherText']?.toString().trim().isNotEmpty ?? false);
    final hasLegacyBackup =
        (data['msgBackupCipherText']?.toString().trim().isNotEmpty ?? false);
    final hasIncrementalBackups = (await _firestore
            .collection('users')
            .doc(uid)
            .collection('message_backups')
            .limit(1)
            .get(const GetOptions(source: Source.server)))
        .docs
        .isNotEmpty;

    return RemoteBackupStatus(
      hasRecoveryPayload: hasRecoveryPayload,
      hasPinMetadata: hasPinMetadata,
      hasMessageBackup: hasLegacyBackup || hasIncrementalBackups,
    );
  }

  Future<String> getCurrentUserPublicKeyBase64() async {
    await ensureIdentityForCurrentUser();
    final keyPair = await _readCurrentUserKeyPair();
    return keyPair.publicKeyPem;
  }

  Future<String?> getUserPublicKeyBase64(
    String uid, {
    bool forceRefresh = false,
  }) async {
    final publicKey = await _readUserPublicKey(uid, forceRefresh: forceRefresh);
    if (publicKey == null) return null;

    // Ensure it's actually an RSA PEM key. If not, it's a legacy account.
    if (!publicKey.contains('PUBLIC KEY')) {
      if (!forceRefresh) {
        return getUserPublicKeyBase64(uid, forceRefresh: true);
      }
      return null;
    }
    return publicKey;
  }

  Future<String> setupZeroKnowledgePin({
    required String pin,
  }) async {
    final String normalizedPin = pin.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(normalizedPin)) {
      throw Exception('PIN must be exactly 6 digits.');
    }

    final String uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }

    final List<int> pinSalt = _randomBytes(16);
    final String derivedPassphrase = await _derivePinPassphrase(
      pin: normalizedPin,
      salt: pinSalt,
    );
    final String recoveryCode = _generateRecoveryCode();
    final List<int> masterSalt = _randomBytes(16);
    final List<int> masterNonce = _randomBytes(12);
    final SecretKey masterKey = await _deriveRecoverySecretKey(
      passphrase: recoveryCode,
      salt: masterSalt,
    );
    final SecretBox masterSecretBox = await _cipher.encrypt(
      utf8.encode(derivedPassphrase),
      secretKey: masterKey,
      nonce: masterNonce,
    );

    await saveRecoveryKeyBackup(passphrase: derivedPassphrase);
    await _firestore.collection('users').doc(uid).set({
      'zkPinEnabled': true,
      'zkPinIterations': _recoveryIterations,
      'zkPinSalt': base64Encode(pinSalt),
      'zkMasterKeyAlgorithm': _recoveryAlgorithm,
      'zkMasterKeySalt': base64Encode(masterSalt),
      'zkMasterKeyNonce': base64Encode(masterSecretBox.nonce),
      'zkMasterKeyMac': base64Encode(masterSecretBox.mac.bytes),
      'zkMasterKeyCipherText': base64Encode(masterSecretBox.cipherText),
      'zkRecoveryUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    await _secureStorage.write(
      key: '$_zeroKnowledgePassphrasePrefix$uid',
      value: derivedPassphrase,
    );

    // Confirm the account doc contains both the recovery backup payload and
    // the PIN metadata. Without both, the user would be prompted to set up a
    // PIN again even though setup appeared to succeed.
    try {
      final verify = await _firestore
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      final vData = verify.data() ?? const <String, dynamic>{};
      if ((vData['e2eeRecoveryCipherText']?.toString() ?? '').isEmpty ||
          (vData['zkPinSalt']?.toString() ?? '').isEmpty ||
          vData['zkPinEnabled'] != true) {
        throw Exception(
          'PIN setup could not be confirmed on the server. '
          'Please try again.',
        );
      }
    } on FirebaseException catch (fe) {
      if (fe.code == 'unavailable' || fe.code == 'failed-precondition') {
        throw Exception(
          'You appear to be offline. Please connect to the internet and '
          'try setting up your backup PIN again.',
        );
      }
      rethrow;
    }

    return recoveryCode;
  }

  Future<void> restoreFromPin({
    required String pin,
  }) async {
    final String uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    final DocumentSnapshot<Map<String, dynamic>> userDoc = await _firestore
        .collection('users')
        .doc(uid)
        .get(const GetOptions(source: Source.server));
    final Map<String, dynamic> data = userDoc.data() ?? <String, dynamic>{};
    final String saltB64 = data['zkPinSalt']?.toString() ?? '';
    if (saltB64.isEmpty) {
      await _restoreFromLegacyPin(pin.trim());
      return;
    }

    final String derivedPassphrase = await _derivePinPassphrase(
      pin: pin.trim(),
      salt: base64Decode(saltB64),
    );
    if (_hasRecoveryPayload(data)) {
      await restoreIdentityFromRecoveryKey(passphrase: derivedPassphrase);
    } else if (!await _hasLocalIdentity(uid)) {
      throw Exception(
        'Your PIN exists on the server, but the encrypted identity backup is '
        'incomplete. Try your recovery code or reset via email.',
      );
    }
    await _secureStorage.write(
      key: '$_zeroKnowledgePassphrasePrefix$uid',
      value: derivedPassphrase,
    );
    await ensureReady(syncRemote: true);
    await syncAutomaticAccountBackupIfAvailable();
  }

  Future<void> _restoreFromLegacyPin(String normalizedPin) async {
    if (!RegExp(r'^\d{6}$').hasMatch(normalizedPin)) {
      throw Exception('PIN must be exactly 6 digits.');
    }

    final String legacyPassphrase = '${normalizedPin}SSPH';
    await restoreIdentityFromRecoveryKey(passphrase: legacyPassphrase);
    final String uid = currentUserId;
    if (uid.isNotEmpty) {
      await _secureStorage.write(
        key: '$_zeroKnowledgePassphrasePrefix$uid',
        value: legacyPassphrase,
      );
    }
  }

  Future<void> restoreFromRecoveryCode({
    required String recoveryCode,
  }) async {
    final String uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }

    final DocumentSnapshot<Map<String, dynamic>> userDoc = await _firestore
        .collection('users')
        .doc(uid)
        .get(const GetOptions(source: Source.server));
    final Map<String, dynamic> data = userDoc.data() ?? <String, dynamic>{};
    final String saltB64 = data['zkMasterKeySalt']?.toString() ?? '';
    final String nonceB64 = data['zkMasterKeyNonce']?.toString() ?? '';
    final String macB64 = data['zkMasterKeyMac']?.toString() ?? '';
    final String cipherTextB64 =
        data['zkMasterKeyCipherText']?.toString() ?? '';
    if (saltB64.isEmpty ||
        nonceB64.isEmpty ||
        macB64.isEmpty ||
        cipherTextB64.isEmpty) {
      throw Exception('Recovery code backup was not found.');
    }

    try {
      final SecretKey masterKey = await _deriveRecoverySecretKey(
        passphrase: recoveryCode.trim().toUpperCase(),
        salt: base64Decode(saltB64),
      );
      final List<int> clearBytes = await _cipher.decrypt(
        SecretBox(
          base64Decode(cipherTextB64),
          nonce: base64Decode(nonceB64),
          mac: Mac(base64Decode(macB64)),
        ),
        secretKey: masterKey,
      );
      final String derivedPassphrase = utf8.decode(clearBytes);
      await restoreIdentityFromRecoveryKey(passphrase: derivedPassphrase);
      await _secureStorage.write(
        key: '$_zeroKnowledgePassphrasePrefix$uid',
        value: derivedPassphrase,
      );
      await ensureReady(syncRemote: true);
      await syncAutomaticAccountBackupIfAvailable();
    } catch (_) {
      throw Exception('Recovery code is incorrect.');
    }
  }

  Future<void> resetEncryptedHistoryForEmailRecovery() async {
    final String uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    final CollectionReference<Map<String, dynamic>> backupCollection =
        _firestore.collection('users').doc(uid).collection('message_backups');
    final QuerySnapshot<Map<String, dynamic>> backups =
        await backupCollection.get();
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in backups.docs) {
      await doc.reference.delete();
    }
    await clearRemoteBackup();
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

    final privateKeyPEM =
        await _secureStorage.read(key: 'hybrid_rsa_private_key');
    final publicKeyPEM =
        await _secureStorage.read(key: 'hybrid_rsa_public_key');

    if (privateKeyPEM == null ||
        privateKeyPEM.isEmpty ||
        publicKeyPEM == null ||
        publicKeyPEM.isEmpty) {
      throw Exception('Encrypted identity is not ready yet.');
    }

    final payloadJson = jsonEncode({
      'version': _recoveryVersion,
      'algorithm': _algorithm,
      'privateKey': privateKeyPEM,
      'publicKey': publicKeyPEM,
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

    final docRef = _firestore.collection('users').doc(uid);
    await docRef.set({
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

    // Verify the write actually reached the server (catches the case where
    // the write was queued offline and the local Future resolved without
    // the data ever persisting to Firestore).
    try {
      final verify = await docRef.get(const GetOptions(source: Source.server));
      final vData = verify.data() ?? const <String, dynamic>{};
      if ((vData['e2eeRecoveryCipherText']?.toString() ?? '').isEmpty) {
        throw Exception(
          'Backup could not be confirmed on the server. '
          'Please check your internet connection and try again.',
        );
      }
    } on FirebaseException catch (fe) {
      if (fe.code == 'unavailable' || fe.code == 'failed-precondition') {
        throw Exception(
          'You appear to be offline. Please connect to the internet and '
          'try setting up your backup PIN again.',
        );
      }
      rethrow;
    }

    await docRef.update({
      'msgBackupVersion': FieldValue.delete(),
      'msgBackupSalt': FieldValue.delete(),
      'msgBackupNonce': FieldValue.delete(),
      'msgBackupMac': FieldValue.delete(),
      'msgBackupCipherText': FieldValue.delete(),
      'msgBackupUpdatedAt': FieldValue.delete(),
    });
    await _saveInitialMessageBackup(uid: uid, passphrase: trimmed);
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

    final userDoc = await _firestore
        .collection('users')
        .doc(uid)
        .get(const GetOptions(source: Source.server));
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

    late final String privateKeyPEM;
    late final String publicKeyPEM;
    try {
      final clearBytes = await _cipher.decrypt(
        secretBox,
        secretKey: recoveryKey,
      );
      final payload =
          jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
      privateKeyPEM = payload['privateKey']?.toString() ?? '';
      publicKeyPEM = payload['publicKey']?.toString() ?? '';
    } catch (_) {
      throw Exception('Recovery key is incorrect.');
    }

    if (privateKeyPEM.isEmpty || publicKeyPEM.isEmpty) {
      throw Exception('Recovery key backup is corrupt.');
    }

    await _rememberCurrentLocalIdentity(
      uid: uid,
      replacingWithPublicKeyPEM: publicKeyPEM,
    );
    await _secureStorage.write(
      key: 'hybrid_rsa_private_key',
      value: privateKeyPEM,
    );
    await _secureStorage.write(
      key: 'hybrid_rsa_public_key',
      value: publicKeyPEM,
    );
    await _firestore.collection('users').doc(uid).set({
      'e2eeEnabled': true,
      'e2eeVersion': 1,
      'e2eeAlgorithm': _algorithm,
      'e2eePublicKey': publicKeyPEM,
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

    await ensureIdentityForCurrentUser();

    await _restoreMessageBackups(
      uid: uid,
      passphrase: trimmed,
      userData: data,
    );
  }

  Future<void> clearRemoteBackup() async {
    final uid = currentUserId;
    if (uid.isEmpty) return;

    await _firestore.collection('users').doc(uid).update({
      'e2eeRecoveryEnabled': FieldValue.delete(),
      'e2eeRecoveryVersion': FieldValue.delete(),
      'e2eeRecoveryAlgorithm': FieldValue.delete(),
      'e2eeRecoveryIterations': FieldValue.delete(),
      'e2eeRecoverySalt': FieldValue.delete(),
      'e2eeRecoveryNonce': FieldValue.delete(),
      'e2eeRecoveryMac': FieldValue.delete(),
      'e2eeRecoveryCipherText': FieldValue.delete(),
      'e2eeRecoveryUpdatedAt': FieldValue.delete(),
      'msgBackupVersion': FieldValue.delete(),
      'msgBackupSalt': FieldValue.delete(),
      'msgBackupNonce': FieldValue.delete(),
      'msgBackupMac': FieldValue.delete(),
      'msgBackupCipherText': FieldValue.delete(),
      'msgBackupUpdatedAt': FieldValue.delete(),
      'zkPinEnabled': FieldValue.delete(),
      'zkPinIterations': FieldValue.delete(),
      'zkPinSalt': FieldValue.delete(),
      'zkMasterKeyAlgorithm': FieldValue.delete(),
      'zkMasterKeySalt': FieldValue.delete(),
      'zkMasterKeyNonce': FieldValue.delete(),
      'zkMasterKeyMac': FieldValue.delete(),
      'zkMasterKeyCipherText': FieldValue.delete(),
      'zkRecoveryUpdatedAt': FieldValue.delete(),
    });
    await _secureStorage.delete(key: '$_zeroKnowledgePassphrasePrefix$uid');
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

    String? passphrase;
    try {
      passphrase = await _secureStorage.read(
        key: '$_accountBackupPassphrasePrefix$uid',
      );
    } catch (error) {
      if (_isKeystoreCorruptionError(error)) {
        // Keystore invalidated — passphrase is unreadable. Return false so
        // bootstrapIfNeeded's outer catch can wipe and regenerate cleanly.
        debugPrint(
          '[E2eeService] Keystore error reading backup passphrase '
          '(will be handled by bootstrapIfNeeded): $error',
        );
        rethrow;
      }
      return false;
    }
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

  // ── Keystore repair helpers ──────────────────────────────────────────────

  /// Returns true when the exception is a Flutter Secure Storage
  /// BadPaddingException / BAD_DECRYPT — which means the Android Keystore
  /// encryption key has been invalidated (fingerprint change, device restore,
  /// app reinstall with different signing key, etc.).
  bool _isKeystoreCorruptionError(Object error) {
    if (error is PlatformException) {
      final msg = (error.message ?? '').toLowerCase();
      final code = (error.code).toLowerCase();
      return msg.contains('bad_decrypt') ||
          msg.contains('badpaddingexception') ||
          msg.contains('bad padding') ||
          code == 'read' ||
          code == 'exception encountered';
    }
    return false;
  }

  /// Wipes every secure-storage key owned by this service for [uid].
  /// Called when the Android Keystore has been invalidated so a fresh
  /// identity can be generated without the corrupted data blocking startup.
  Future<void> _deleteAllSecureStorageKeysForUser(String uid) async {
    final keys = [
      'hybrid_rsa_private_key',
      'hybrid_rsa_public_key',
      '$_accountBackupPassphrasePrefix$uid',
      '$_bootstrappedMarkerPrefix$uid',
    ];
    for (final key in keys) {
      try {
        await _secureStorage.delete(key: key);
      } catch (_) {}
    }
    // Also reset all in-memory caches so the next read starts clean.
    _cachedKeyPairUserId = null;
    _cachedCurrentUserKeyPair = null;
    _keyPairFuture = null;
    _ensuredUserId = null;
    _ensureIdentityFuture = null;
    debugPrint('[E2eeService] Wiped corrupted Keystore entries for $uid');
  }

  Future<void> bootstrapIfNeeded({
    String? accountPassword,
    bool syncRemote = true,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      return;
    }

    try {
      await _bootstrapIfNeededInternal(
        uid: uid,
        accountPassword: accountPassword,
        syncRemote: syncRemote,
      );
    } catch (error) {
      if (_isKeystoreCorruptionError(error)) {
        // The Android Keystore encryption key was invalidated (e.g. the user
        // changed their fingerprint or PIN, the device was restored, or the
        // app was reinstalled with a different signing key). The encrypted
        // values in FlutterSecureStorage are permanently unreadable.
        // Solution: wipe them and regenerate a fresh identity so the user
        // can keep using the app without being stuck in a crash loop.
        debugPrint(
          '[E2eeService] Keystore corruption detected — wiping secure '
          'storage and regenerating identity. Error: $error',
        );
        await _deleteAllSecureStorageKeysForUser(uid);
        // Retry once with a clean slate — this time there are no corrupted
        // entries so _ensureLocalIdentityForCurrentUser will generate new keys.
        try {
          await _bootstrapIfNeededInternal(
            uid: uid,
            accountPassword: accountPassword,
            syncRemote: syncRemote,
          );
        } catch (retryError) {
          debugPrint(
            '[E2eeService] Bootstrap retry after Keystore wipe failed '
            '(non-fatal, will retry on next launch): $retryError',
          );
        }
      } else {
        rethrow;
      }
    }
  }

  Future<void> _bootstrapIfNeededInternal({
    required String uid,
    String? accountPassword,
    bool syncRemote = true,
  }) async {
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
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await bootstrapIfNeeded(accountPassword: accountPassword);
          return;
        } catch (error) {
          debugPrint(
            '[E2eeService] Bootstrap attempt ${attempt + 1}/3 failed: $error',
          );
          if (attempt < 2) {
            // Exponential backoff: 5s then 10s before the final attempt.
            await Future.delayed(Duration(seconds: 5 * (1 << attempt)));
          }
        }
      }
    }());
  }

  void scheduleAutomaticAccountBootstrapIfPossible() {
    unawaited(() async {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          await bootstrapIfNeeded();
          return;
        } catch (error) {
          debugPrint(
            '[E2eeService] Bootstrap (no-pw) attempt ${attempt + 1}/3 failed: $error',
          );
          if (attempt < 2) {
            await Future.delayed(Duration(seconds: 5 * (1 << attempt)));
          }
        }
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

    String? passphrase = await _secureStorage.read(
      key: '$_accountBackupPassphrasePrefix$uid',
    );
    // PIN-based backup stores a derived passphrase under the ZK prefix.
    passphrase ??= await _secureStorage.read(
      key: '$_zeroKnowledgePassphrasePrefix$uid',
    );
    if (passphrase == null || passphrase.isEmpty) {
      return;
    }
    final backupPassphrase = passphrase;

    final inFlight = _automaticBackupSyncFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      try {
        await ensureIdentityForCurrentUser(forceRepublish: false);
        await _saveIncrementalMessageBackup(
          uid: uid,
          passphrase: backupPassphrase,
        );
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

  Future<void> deactivateCurrentDevice([String? userId]) async {}

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

    // Background: hydrate + keep chat cache up-to-date even if the user
    // doesn’t open each conversation. This is how a fresh device ends up with
    // locally cached plaintext after restoring message_backups.
    _startOnlineChatHydration(uid);
    unawaited(_hydrateRecentOnlineChatsOnce(uid));
  }

  void _startOnlineChatHydration(String uid) {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) return;

    if (_onlineChatHydrationSubscription != null &&
        _onlineChatHydrationUserId == trimmedUid) {
      return;
    }

    unawaited(_onlineChatHydrationSubscription?.cancel());
    _onlineChatHydrationSubscription = null;
    _onlineChatHydrationUserId = trimmedUid;
    _onlineChatSeenLatestMessageKeys.clear();

    // Listen to chat summaries. When a new lastMessage appears, decrypt it
    // via ChatEncryptionRepository.refreshConversationPreview(), which also
    // persists the message projection + plaintext to local cache.
    _onlineChatHydrationSubscription = _firestore
        .collection('chats')
        .where('participants', arrayContains: trimmedUid)
        .snapshots()
        .listen((snapshot) {
      final changes = snapshot.docChanges.isNotEmpty
          ? snapshot.docChanges
              .where((change) => change.type != DocumentChangeType.removed)
              .map((change) => change.doc)
              .toList(growable: false)
          : snapshot.docs;

      for (final doc in changes) {
        final chatId = doc.id.trim();
        if (chatId.isEmpty) continue;
        final data = doc.data() ?? const <String, dynamic>{};
        final lastMessageId =
            data['lastMessageClientMessageId']?.toString().trim() ?? '';
        if (lastMessageId.isEmpty) continue;

        // Dedupe: chatId + message id is enough to know if we’ve already
        // hydrated this message on this run.
        final hydrateKey = '$chatId|$lastMessageId';
        if (_onlineChatSeenLatestMessageKeys.contains(hydrateKey)) {
          continue;
        }
        _onlineChatSeenLatestMessageKeys.add(hydrateKey);
        if (_onlineChatSeenLatestMessageKeys.length > 800) {
          // Prevent unbounded growth on long sessions.
          _onlineChatSeenLatestMessageKeys.clear();
        }

        unawaited(() async {
          try {
            await _chatEncryptionRepository.refreshConversationPreview(
              conversationId: chatId,
              chatData: data,
            );
            // After cache is updated, push an incremental encrypted backup
            // (no-op if the user hasn’t enabled backup PIN on this device).
            await syncAutomaticAccountBackupIfAvailable();
          } catch (e) {
            debugPrint('[E2eeService] Chat hydration skipped: $e');
          }
        }());
      }
    }, onError: (Object e) {
      debugPrint('[E2eeService] Chat hydration listener failed: $e');
    });
  }

  Future<void> _hydrateRecentOnlineChatsOnce(String uid) async {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) return;

    if (_onlineChatInitialHydrationFuture != null &&
        _onlineChatInitialHydrationUserId == trimmedUid) {
      return _onlineChatInitialHydrationFuture!;
    }

    final future = _hydrateRecentOnlineChats(uid: trimmedUid);
    _onlineChatInitialHydrationFuture = future;
    _onlineChatInitialHydrationUserId = trimmedUid;
    try {
      return await future;
    } finally {
      if (identical(_onlineChatInitialHydrationFuture, future)) {
        _onlineChatInitialHydrationFuture = null;
        _onlineChatInitialHydrationUserId = null;
      }
    }
  }

  Future<void> _hydrateRecentOnlineChats({
    required String uid,
    int perChatLimit = 40,
  }) async {
    try {
      final chatsSnapshot = await _firestore
          .collection('chats')
          .where('participants', arrayContains: uid)
          .get();

      for (final chatDoc in chatsSnapshot.docs) {
        try {
          final chatId = chatDoc.id.trim();
          final chatData = chatDoc.data();
          final rawParticipants = chatData['participants'];
          final participants = (rawParticipants is Iterable)
              ? rawParticipants
                  .map((value) => value?.toString().trim() ?? '')
                  .where((value) => value.isNotEmpty)
                  .toList(growable: false)
              : const <String>[];
          final otherUserId = participants.firstWhere(
            (id) => id != uid,
            orElse: () => '',
          );
          if (otherUserId.isEmpty) {
            continue;
          }

          QuerySnapshot<Map<String, dynamic>> messageSnapshot;
          try {
            messageSnapshot = await _firestore
                .collection('chats')
                .doc(chatId)
                .collection('messages')
                .orderBy('timestamp', descending: true)
                .limit(perChatLimit)
                .get();
          } catch (_) {
            // Fallback: for legacy messages that might not have 'timestamp'.
            messageSnapshot = await _firestore
                .collection('chats')
                .doc(chatId)
                .collection('messages')
                .limit(perChatLimit)
                .get();
          }
          if (messageSnapshot.docs.isEmpty) {
            continue;
          }

          await _chatEncryptionRepository.syncConversationSnapshot(
            otherUserId: otherUserId,
            docs: messageSnapshot.docs,
          );
        } catch (e) {
          debugPrint('[E2eeService] Chat hydration skipped for one chat: $e');
        }
      }

      // After initial hydration, attempt to push an incremental backup (safe no-op
      // when backup PIN isn’t available).
      await syncAutomaticAccountBackupIfAvailable();
    } catch (e) {
      debugPrint('[E2eeService] Initial chat hydration skipped: $e');
    }
  }

  Future<String> createPendingOutgoingMessageProjection({
    required String conversationId,
    required String receiverId,
    required String plaintext,
  }) {
    return _chatEncryptionRepository.createPendingOutgoingMessageProjection(
      conversationId: conversationId,
      receiverId: receiverId,
      plaintext: plaintext,
      messageType: 'text',
    );
  }

  Future<void> failOutgoingMessageProjection({
    required String clientMessageId,
    required String conversationId,
    required String reason,
  }) {
    return _chatEncryptionRepository.failOutgoingMessageProjection(
      clientMessageId: clientMessageId,
      conversationId: conversationId,
      reason: reason,
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
    if (senderId.trim().isEmpty || receiverId.trim().isEmpty || bytes.isEmpty) {
      return;
    }

    await _chatEncryptionRepository.cacheOutgoingMediaBytes(
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
    if (senderId.trim().isEmpty || receiverId.trim().isEmpty || bytes.isEmpty) {
      return;
    }

    await _chatEncryptionRepository.cacheIncomingMediaBytes(
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
    return _chatEncryptionRepository.getCachedMediaBytes(
      cacheKey: cacheKey,
      clientMessageId: clientMessageId,
      messageId: messageId,
      fileName: fileName,
    );
  }

  String? getSeededDecryptedText(Map<String, dynamic> data) {
    final cacheKey = data['e2eeCacheKey']?.toString().trim() ?? '';
    if (cacheKey.isNotEmpty) {
      final cached = _chatEncryptionRepository.peekCachedPlaintext(cacheKey);
      if (cached != null && cached.trim().isNotEmpty) {
        return cached;
      }
    }
    return null;
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
      // Delegate all key generation and storage to the centralized SecurityService
      await SecurityService().ensureKeysUploaded();

      final publicKeyPEM =
          await _secureStorage.read(key: 'hybrid_rsa_public_key') ?? '';

      _cachedKeyPairUserId = uid;
      _publicKeyCache[uid] = publicKeyPEM;
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
    final publicKeyPEM = keyPair.publicKeyPem;

    final inFlight = _remoteIdentitySyncFuture;
    if (inFlight != null) {
      await inFlight;
      if (_syncedRemoteIdentityUserId == uid &&
          _syncedRemoteIdentityPublicKey == publicKeyPEM &&
          !forceRepublish) {
        return;
      }
    }

    if (_syncedRemoteIdentityUserId == uid &&
        _syncedRemoteIdentityPublicKey == publicKeyPEM &&
        !forceRepublish) {
      return;
    }

    final future = () async {
      final userDoc = await _firestore.collection('users').doc(uid).get();
      final data = userDoc.data() ?? const <String, dynamic>{};
      final existingRemotePublicKey =
          data['e2eePublicKey']?.toString().trim() ?? '';
      final alreadyPublished = existingRemotePublicKey == publicKeyPEM &&
          data['e2eeEnabled'] == true;

      if (forceRepublish || !alreadyPublished) {
        await _publishIdentityDocument(
          uid: uid,
          publicKeyPEM: publicKeyPEM,
        );
        await SecurityService().ensureKeysUploaded();
      }

      _syncedRemoteIdentityUserId = uid;
      _syncedRemoteIdentityPublicKey = publicKeyPEM;
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
    required String publicKeyPEM,
  }) async {
    await _firestore.collection('users').doc(uid).set({
      'e2eeEnabled': true,
      'e2eeVersion': 1,
      'e2eeAlgorithm': _algorithm,
      'e2eePublicKey': publicKeyPEM,
      'e2eeUpdatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<RSAKeyPairData> _readCurrentUserKeyPair() async {
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
      final privateKeyPEM =
          await _secureStorage.read(key: 'hybrid_rsa_private_key');
      final publicKeyPEM =
          await _secureStorage.read(key: 'hybrid_rsa_public_key');

      if (privateKeyPEM == null ||
          privateKeyPEM.isEmpty ||
          publicKeyPEM == null ||
          publicKeyPEM.isEmpty) {
        throw Exception('Encrypted identity is not ready.');
      }

      _cachedCurrentUserKeyPair = RSAKeyPairData(
        privateKeyPEM,
        publicKeyPEM,
      );
      _cachedKeyPairUserId = uid;
      _publicKeyCache[uid] = publicKeyPEM;
      return _cachedCurrentUserKeyPair!;
    }();

    try {
      return await _keyPairFuture!;
    } finally {
      _keyPairFuture = null;
    }
  }

  List<int> _randomBytes(int length) {
    return List<int>.generate(length, (_) => _random.nextInt(256));
  }

  Future<void> _saveInitialMessageBackup({
    required String uid,
    required String passphrase,
  }) async {
    try {
      final messages = await _localCache.exportAllMessages(uid);
      if (messages.isEmpty) return;

      final payloadJson = jsonEncode({
        'version': 2,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'messages': messages,
      });

      final salt = _randomBytes(16);
      final nonce = _randomBytes(12);
      final key =
          await _deriveRecoverySecretKey(passphrase: passphrase, salt: salt);
      final secretBox = await _cipher.encrypt(
        utf8.encode(payloadJson),
        secretKey: key,
        nonce: nonce,
      );

      final backupCollection =
          _firestore.collection('users').doc(uid).collection('message_backups');

      final oldChunks = await backupCollection.get();
      for (final doc in oldChunks.docs) {
        await doc.reference.delete();
      }

      await backupCollection.add({
        'version': 2,
        'salt': base64Encode(salt),
        'nonce': base64Encode(secretBox.nonce),
        'mac': base64Encode(secretBox.mac.bytes),
        'cipherText': base64Encode(secretBox.cipherText),
        'savedAt': FieldValue.serverTimestamp(),
      });
      debugPrint(
          '[E2eeService] Initial message backup saved: ${messages.length} messages');
    } catch (error) {
      debugPrint('[E2eeService] Initial message backup save skipped: $error');
    }
  }

  Future<void> _saveIncrementalMessageBackup({
    required String uid,
    required String passphrase,
  }) async {
    try {
      final backupCollection =
          _firestore.collection('users').doc(uid).collection('message_backups');

      final lastBackupSnapshot = await backupCollection
          .orderBy('savedAt', descending: true)
          .limit(1)
          .get();

      int lastBackupTimestampMs = 0;
      if (lastBackupSnapshot.docs.isNotEmpty) {
        final lastBackupData = lastBackupSnapshot.docs.first.data();
        final savedAt = lastBackupData['savedAt'];
        if (savedAt is Timestamp) {
          lastBackupTimestampMs = savedAt.millisecondsSinceEpoch;
        }
      }

      final messages = await _localCache.exportAllMessagesSince(
        uid,
        lastBackupTimestampMs,
      );

      if (messages.isEmpty) {
        debugPrint('[E2eeService] No new messages to back up.');
        return;
      }

      final now = DateTime.now().toUtc();
      final payloadJson = jsonEncode({
        'version': 2,
        'savedAt': now.toIso8601String(),
        'messages': messages,
      });

      final salt = _randomBytes(16);
      final nonce = _randomBytes(12);
      final key =
          await _deriveRecoverySecretKey(passphrase: passphrase, salt: salt);
      final secretBox = await _cipher.encrypt(
        utf8.encode(payloadJson),
        secretKey: key,
        nonce: nonce,
      );

      await backupCollection.add({
        'version': 2,
        'salt': base64Encode(salt),
        'nonce': base64Encode(secretBox.nonce),
        'mac': base64Encode(secretBox.mac.bytes),
        'cipherText': base64Encode(secretBox.cipherText),
        'savedAt': FieldValue.serverTimestamp(),
      });
      debugPrint(
          '[E2eeService] Incremental backup saved: ${messages.length} new messages');
    } catch (error) {
      debugPrint('[E2eeService] Incremental message backup failed: $error');
    }
  }

  Future<void> _restoreMessageBackups({
    required String uid,
    required String passphrase,
    required Map<String, dynamic> userData,
  }) async {
    final oldCipherTextB64 = userData['msgBackupCipherText']?.toString() ?? '';
    if (oldCipherTextB64.isNotEmpty) {
      debugPrint(
          '[E2eeService] Found legacy message backup, attempting restore...');
      await _restoreLegacyMessageBackup(
        uid: uid,
        passphrase: passphrase,
        userData: userData,
      );
    }

    try {
      final backupCollection =
          _firestore.collection('users').doc(uid).collection('message_backups');

      final backupChunksSnapshot =
          await backupCollection.orderBy('savedAt').get();
      if (backupChunksSnapshot.docs.isEmpty) {
        if (oldCipherTextB64.isEmpty) {
          debugPrint('[E2eeService] No message backups found to restore.');
        }
        return;
      }

      debugPrint(
          '[E2eeService] Found ${backupChunksSnapshot.docs.length} incremental backup chunks, restoring...');
      int totalMessagesRestored = 0;

      for (final chunkDoc in backupChunksSnapshot.docs) {
        final chunkData = chunkDoc.data();
        final cipherTextB64 = chunkData['cipherText']?.toString() ?? '';
        final saltB64 = chunkData['salt']?.toString() ?? '';
        final nonceB64 = chunkData['nonce']?.toString() ?? '';
        final macB64 = chunkData['mac']?.toString() ?? '';

        if (cipherTextB64.isEmpty ||
            saltB64.isEmpty ||
            nonceB64.isEmpty ||
            macB64.isEmpty) {
          continue;
        }

        try {
          final key = await _deriveRecoverySecretKey(
            passphrase: passphrase,
            salt: base64Decode(saltB64),
          );
          final secretBox = SecretBox(
            base64Decode(cipherTextB64),
            nonce: base64Decode(nonceB64),
            mac: Mac(base64Decode(macB64)),
          );
          final clearBytes = await _cipher.decrypt(secretBox, secretKey: key);
          final payload =
              jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
          final messages = payload['messages'] as List<dynamic>? ?? const [];

          if (messages.isNotEmpty) {
            await _localCache.importAllMessages(uid, messages);
            totalMessagesRestored += messages.length;
          }
        } catch (error) {
          debugPrint(
              '[E2eeService] Failed to decrypt a backup chunk, skipping. Error: $error');
        }
      }
      debugPrint(
          '[E2eeService] Incremental backup restored: $totalMessagesRestored messages from ${backupChunksSnapshot.docs.length} chunks.');
    } catch (error) {
      debugPrint(
          '[E2eeService] Incremental message backup restore failed: $error');
    }
  }

  Future<void> _restoreLegacyMessageBackup({
    required String uid,
    required String passphrase,
    required Map<String, dynamic> userData,
  }) async {
    final cipherTextB64 = userData['msgBackupCipherText']?.toString() ?? '';
    final saltB64 = userData['msgBackupSalt']?.toString() ?? '';
    final nonceB64 = userData['msgBackupNonce']?.toString() ?? '';
    final macB64 = userData['msgBackupMac']?.toString() ?? '';

    if (cipherTextB64.isEmpty ||
        saltB64.isEmpty ||
        nonceB64.isEmpty ||
        macB64.isEmpty) {
      return;
    }

    try {
      final key = await _deriveRecoverySecretKey(
        passphrase: passphrase,
        salt: base64Decode(saltB64),
      );
      final secretBox = SecretBox(
        base64Decode(cipherTextB64),
        nonce: base64Decode(nonceB64),
        mac: Mac(base64Decode(macB64)),
      );
      final clearBytes = await _cipher.decrypt(secretBox, secretKey: key);
      final payload =
          jsonDecode(utf8.decode(clearBytes)) as Map<String, dynamic>;
      final messages = payload['messages'] as List<dynamic>? ?? const [];
      await _localCache.importAllMessages(uid, messages);
      debugPrint(
          '[E2eeService] Legacy message backup restored: ${messages.length} messages');
    } catch (error) {
      debugPrint('[E2eeService] Legacy message backup restore skipped: $error');
    }
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

  Future<String> _derivePinPassphrase({
    required String pin,
    required List<int> salt,
  }) async {
    final SecretKey key = await _deriveRecoverySecretKey(
      passphrase: pin,
      salt: salt,
    );
    final List<int> bytes = await key.extractBytes();
    return base64UrlEncode(bytes);
  }

  String _generateRecoveryCode() {
    const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final StringBuffer buffer = StringBuffer();
    for (int index = 0; index < 16; index++) {
      if (index > 0 && index % 4 == 0) {
        buffer.write('-');
      }
      buffer.write(alphabet[_random.nextInt(alphabet.length)]);
    }
    return buffer.toString();
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
    String? privateKeyPEM;
    String? publicKeyPEM;
    try {
      privateKeyPEM = await _secureStorage.read(key: 'hybrid_rsa_private_key');
      publicKeyPEM = await _secureStorage.read(key: 'hybrid_rsa_public_key');
    } catch (error) {
      if (_isKeystoreCorruptionError(error)) {
        // Keystore is corrupted — treat as no local identity so bootstrap
        // regenerates keys after wiping the corrupted entries.
        debugPrint(
          '[E2eeService] Keystore error in _hasLocalIdentity — '
          'treating as no identity: $error',
        );
        return false;
      }
    }
    return privateKeyPEM != null &&
        privateKeyPEM.isNotEmpty &&
        publicKeyPEM != null &&
        publicKeyPEM.isNotEmpty;
  }

  Future<bool> _hasRemoteRecoveryBackup(String uid) async {
    // Always fetch from the server so a stale local cache or an offline-queued
    // write that never committed doesn't produce a false positive.
    final userDoc = await _firestore
        .collection('users')
        .doc(uid)
        .get(const GetOptions(source: Source.server));
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

  bool _hasRecoveryPayload(Map<String, dynamic> data) {
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
    _automaticBackupBootstrapFuture = null;
  }

  Future<String?> _readUserPublicKey(String uid,
      {bool forceRefresh = false}) async {
    if (!forceRefresh && _publicKeyCache.containsKey(uid)) {
      final cached = _publicKeyCache[uid];
      // Reject stale cached keys and force a refresh to get the RSA PEM.
      if (cached != null && cached.contains('PUBLIC KEY')) {
        return cached;
      }
      forceRefresh = true;
    }
    if (!forceRefresh && _publicKeyFutureCache.containsKey(uid)) {
      return await _publicKeyFutureCache[uid];
    }

    final future = () async {
      try {
        final doc = await _firestore.collection('users').doc(uid).get();
        final data = doc.data();
        if (data != null && data['e2eePublicKey'] != null) {
          final key = data['e2eePublicKey'].toString();
          _publicKeyCache[uid] = key;
          // Only cache valid RSA keys to prevent poisoning the cache with legacy keys
          if (key.contains('PUBLIC KEY')) {
            _publicKeyCache[uid] = key;
          }
          return key;
        }
        return null;
      } catch (e) {
        debugPrint('[E2eeService] Error reading public key for $uid: $e');
        return null;
      }
    }();

    _publicKeyFutureCache[uid] = future;
    try {
      return await future;
    } finally {
      if (identical(_publicKeyFutureCache[uid], future)) {
        _publicKeyFutureCache.remove(uid);
      }
    }
  }

  Future<void> _rememberCurrentLocalIdentity({
    required String uid,
    required String replacingWithPublicKeyPEM,
  }) async {
    _cachedKeyPairUserId = uid;
    _publicKeyCache[uid] = replacingWithPublicKeyPEM;
  }

  String _chatId(String a, String b) {
    final ids = [a, b]..sort();
    return ids.join('_');
  }
}

class RSAKeyPairData {
  final String privateKeyPem;
  final String publicKeyPem;

  RSAKeyPairData(this.privateKeyPem, this.publicKeyPem);
}

class RemoteBackupStatus {
  final bool hasRecoveryPayload;
  final bool hasPinMetadata;
  final bool hasMessageBackup;

  const RemoteBackupStatus({
    required this.hasRecoveryPayload,
    required this.hasPinMetadata,
    required this.hasMessageBackup,
  });

  const RemoteBackupStatus.none()
      : hasRecoveryPayload = false,
        hasPinMetadata = false,
        hasMessageBackup = false;

  bool get requiresPinRestore =>
      hasRecoveryPayload || hasPinMetadata || hasMessageBackup;
}
