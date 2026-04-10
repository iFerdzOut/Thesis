import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:libsignal/libsignal.dart';
import 'package:uuid/uuid.dart';

import '../models/prekey_bundle_model.dart';
import 'libsignal_store_service.dart';
import 'local_message_cache_service.dart';

class KeyManagementService {
  KeyManagementService._internal();

  static final KeyManagementService _instance = KeyManagementService._internal();
  factory KeyManagementService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final LocalMessageCacheService _cacheService = LocalMessageCacheService();
  final Uuid _uuid = const Uuid();
  final Random _random = Random.secure();

  Future<void>? _initFuture;
  String? _initializedUserId;

  static const int _defaultSignalDeviceId = 1;
  static const int _protocolVersion = 2;
  static const int _preKeyBatchSize = 40;
  static const int _preKeyRefillThreshold = 20;

  String get currentUserId => _auth.currentUser?.uid ?? '';

  Future<void> initialize() async {
    if (_initFuture != null) {
      await _initFuture;
      return;
    }
    _initFuture = () async {
      await LibSignal.init();
      await _cacheService.initialize();
    }();
    try {
      await _initFuture;
    } finally {
      _initFuture = null;
    }
  }

  Future<void> ensureDeviceIdentity({
    String? userId,
    bool forceRepublish = false,
  }) async {
    await initialize();
    final uid = userId ?? currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    if (!forceRepublish && _initializedUserId == uid) {
      await _refillPreKeysIfNeeded(uid);
      return;
    }

    var identityRow = await _cacheService.readIdentity(uid);
    if (identityRow == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final identityKeyPair = IdentityKeyPair.generate();
      final registrationId = 1 + _random.nextInt(16380);
      final deviceDocId = _uuid.v4();
      await _cacheService.upsertIdentity(
        userId: uid,
        deviceDocId: deviceDocId,
        signalDeviceId: _defaultSignalDeviceId,
        registrationId: registrationId,
        identityKeyPair: identityKeyPair.serialize(),
      );
      identityRow = await _cacheService.readIdentity(uid);
      if (identityRow == null) {
        throw Exception('Failed to persist Signal identity.');
      }
      await _ensureSignedPreKey(uid, identityKeyPair, nowMs: now);
      await _ensureKyberPreKey(uid, identityKeyPair, nowMs: now);
      await _refillPreKeysIfNeeded(uid, identityKeyPair: identityKeyPair);
    } else {
      final identityKeyPair = IdentityKeyPair.deserialize(
        bytes: _blob(identityRow['identity_key_pair']).toList(),
      );
      await _ensureSignedPreKey(uid, identityKeyPair);
      await _ensureKyberPreKey(uid, identityKeyPair);
      await _refillPreKeysIfNeeded(uid, identityKeyPair: identityKeyPair);
    }

    await _publishPublicBundle(uid);
    _initializedUserId = uid;
  }

  Future<LibsignalStoreService> getStore([String? userId]) async {
    final uid = userId ?? currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    await initialize();
    final identityRow = await _cacheService.readIdentity(uid);
    if (identityRow == null) {
      throw Exception('Signal identity is not initialized.');
    }
    return LibsignalStoreService(userId: uid, cacheService: _cacheService);
  }

  Future<IdentityKeyPair> getIdentityKeyPair([String? userId]) async {
    final store = await getStore(userId);
    return store.getIdentityKeyPair();
  }

  Future<String> getCurrentDeviceDocId([String? userId]) async {
    final store = await getStore(userId);
    return store.getDeviceDocId();
  }

  Future<int> getCurrentSignalDeviceId([String? userId]) async {
    final store = await getStore(userId);
    return store.getSignalDeviceId();
  }

  Future<int> getCurrentRegistrationId([String? userId]) async {
    final store = await getStore(userId);
    return store.getLocalRegistrationId();
  }

  Future<String> getCurrentIdentityPublicKeyBase64([String? userId]) async {
    final identityKeyPair = await getIdentityKeyPair(userId);
    return base64Encode(identityKeyPair.publicKey);
  }

  Future<PreKeyBundleModel?> fetchPeerBundle(
    String peerUserId, {
    required bool consumeOneTimePreKey,
  }) async {
    final bundles = await fetchPeerBundles(
      peerUserId,
      consumeOneTimePreKey: consumeOneTimePreKey,
    );
    return bundles.isEmpty ? null : bundles.first;
  }

  Future<List<PreKeyBundleModel>> fetchPeerBundles(
    String peerUserId, {
    required bool consumeOneTimePreKey,
  }) async {
    await initialize();
    if (peerUserId.trim().isEmpty) return const <PreKeyBundleModel>[];

    final devicesSnapshot = await _firestore
        .collection('users')
        .doc(peerUserId)
        .collection('devices')
        .where('active', isEqualTo: true)
        .get();
    if (devicesSnapshot.docs.isEmpty) {
      return const <PreKeyBundleModel>[];
    }

    final deviceDocs = [...devicesSnapshot.docs]
      ..sort((a, b) {
        final aMs = _timestampMs(a.data()['updatedAt']);
        final bMs = _timestampMs(b.data()['updatedAt']);
        return bMs.compareTo(aMs);
      });
    final bundles = <PreKeyBundleModel>[];
    for (final deviceDoc in deviceDocs) {
      final bundle = await _bundleForDeviceDoc(
        peerUserId: peerUserId,
        deviceDoc: deviceDoc,
        consumeOneTimePreKey: consumeOneTimePreKey,
      );
      if (bundle != null) {
        bundles.add(bundle);
      }
    }
    return bundles;
  }

  Future<PreKeyBundleModel?> fetchPeerBundleForDevice(
    String peerUserId, {
    required String deviceDocId,
    required bool consumeOneTimePreKey,
  }) async {
    await initialize();
    final trimmedPeerUserId = peerUserId.trim();
    final trimmedDeviceDocId = deviceDocId.trim();
    if (trimmedPeerUserId.isEmpty || trimmedDeviceDocId.isEmpty) {
      return null;
    }

    final deviceSnapshot = await _firestore
        .collection('users')
        .doc(trimmedPeerUserId)
        .collection('devices')
        .doc(trimmedDeviceDocId)
        .get();
    if (!deviceSnapshot.exists) {
      return null;
    }
    final deviceData = deviceSnapshot.data();
    if (deviceData == null || deviceData['active'] == false) {
      return null;
    }

    return _bundleForDeviceDoc(
      peerUserId: trimmedPeerUserId,
      deviceDoc: deviceSnapshot,
      consumeOneTimePreKey: consumeOneTimePreKey,
    );
  }

  Future<PreKeyBundleModel?> _bundleForDeviceDoc({
    required String peerUserId,
    required DocumentSnapshot<Map<String, dynamic>> deviceDoc,
    required bool consumeOneTimePreKey,
  }) async {
    final deviceData = deviceDoc.data();
    if (deviceData == null) {
      return null;
    }
    Map<String, dynamic>? oneTimePreKeyData;
    DocumentReference<Map<String, dynamic>>? oneTimePreKeyRef;

    final oneTimePreKeySnapshot = await deviceDoc.reference
        .collection('one_time_prekeys')
        .limit(1)
        .get();
    if (oneTimePreKeySnapshot.docs.isNotEmpty) {
      final preKeyDoc = oneTimePreKeySnapshot.docs.first;
      oneTimePreKeyData = preKeyDoc.data();
      oneTimePreKeyRef = preKeyDoc.reference;
    }

    if (consumeOneTimePreKey && oneTimePreKeyRef != null) {
      await oneTimePreKeyRef.delete();
      await deviceDoc.reference.set({
        'preKeyCount': FieldValue.increment(-1),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    return PreKeyBundleModel.fromFirestore(
      userId: peerUserId,
      deviceDocId: deviceDoc.id,
      deviceData: deviceData,
      oneTimePreKeyData: oneTimePreKeyData,
    );
  }

  Future<Map<String, dynamic>> exportSignalBackupPayload() async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    await ensureDeviceIdentity(userId: uid);
    final store = await getStore(uid);
    final identityRow = await _cacheService.readIdentity(uid);
    return {
      'deviceDocId': await store.getDeviceDocId(),
      'signalDeviceId': await store.getSignalDeviceId(),
      'registrationId': await store.getLocalRegistrationId(),
      'identityPublicKey': await getCurrentIdentityPublicKeyBase64(uid),
      'signalState': await _cacheService.exportSignalState(uid),
      'identityRow': _encodeBlobRow(identityRow ?? <String, dynamic>{}),
    };
  }

  Future<void> restoreSignalBackupPayload(Map<String, dynamic> payload) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('No logged-in user found.');
    }
    await initialize();

    final signalState =
        payload['signalState'] as Map<String, dynamic>? ?? <String, dynamic>{};
    final decodedState = _decodeSignalState(signalState);
    await _cacheService.importSignalState(uid, decodedState);
    await _publishPublicBundle(uid);
    _initializedUserId = uid;
  }

  Future<void> _publishPublicBundle(String uid) async {
    final store = await getStore(uid);
    final identityKeyPair = await store.getIdentityKeyPair();
    final identityPublicKeyBase64 = base64Encode(identityKeyPair.publicKey);
    final deviceDocId = await store.getDeviceDocId();
    final signalDeviceId = await store.getSignalDeviceId();
    final registrationId = await store.getLocalRegistrationId();

    final signedPreKeyIds = await store.getAllSignedPreKeyIds();
    if (signedPreKeyIds.isEmpty) {
      throw Exception('Signed pre-key is missing.');
    }
    final signedPreKeyId = signedPreKeyIds.reduce(max);
    final signedPreKey = await store.loadSignedPreKey(signedPreKeyId);
    if (signedPreKey == null) {
      throw Exception('Signed pre-key is missing.');
    }

    final kyberPreKeyIds = await store.getAllKyberPreKeyIds();
    if (kyberPreKeyIds.isEmpty) {
      throw Exception('Kyber pre-key is missing.');
    }
    final kyberPreKeyId = kyberPreKeyIds.reduce(max);
    final kyberPreKey = await store.loadKyberPreKey(kyberPreKeyId);
    if (kyberPreKey == null) {
      throw Exception('Kyber pre-key is missing.');
    }

    final pendingPreKeys = await _cacheService.getPendingPreKeys(uid);
    for (final row in pendingPreKeys) {
      final preKeyId = (row['prekey_id'] as num?)?.toInt() ?? 0;
      final recordBytes = _blob(row['record']);
      final record = PreKeyRecord.deserialize(bytes: recordBytes.toList());
      await _firestore
          .collection('users')
          .doc(uid)
          .collection('devices')
          .doc(deviceDocId)
          .collection('one_time_prekeys')
          .doc(preKeyId.toString())
          .set({
        'preKeyId': preKeyId,
        'preKeyPublic': base64Encode(record.publicKey()),
        'createdAt': FieldValue.serverTimestamp(),
      });
      await _cacheService.markPreKeyUploaded(userId: uid, preKeyId: preKeyId);
    }

    final pendingKyberKeys = await _cacheService.getPendingKyberPreKeys(uid);
    for (final row in pendingKyberKeys) {
      final preKeyId = (row['prekey_id'] as num?)?.toInt() ?? 0;
      await _cacheService.markKyberPreKeyUploaded(userId: uid, preKeyId: preKeyId);
    }

    final currentPreKeyCount = (await store.getAllPreKeyIds()).length;
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .doc(deviceDocId)
        .set({
      'identityPublicKey': identityPublicKeyBase64,
      'signalDeviceId': signalDeviceId,
      'registrationId': registrationId,
      'signedPreKeyId': signedPreKeyId,
      'signedPreKeyPublic': base64Encode(signedPreKey.publicKey()),
      'signedPreKeySignature': base64Encode(signedPreKey.signature()),
      'kyberPreKeyId': kyberPreKeyId,
      'kyberPreKeyPublic': base64Encode(kyberPreKey.getPublicKey().serialize()),
      'kyberPreKeySignature': base64Encode(kyberPreKey.signature()),
      'preKeyCount': currentPreKeyCount,
      'protocolVersion': _protocolVersion,
      'appVersion': '1.0.0',
      'active': true,
      'updatedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> _ensureSignedPreKey(
    String uid,
    IdentityKeyPair identityKeyPair, {
    int? nowMs,
  }) async {
    final store = await getStore(uid);
    final existing = await store.getAllSignedPreKeyIds();
    if (existing.isNotEmpty) {
      return;
    }
    const int id = 1;
    final privateKey = PrivateKey.generate();
    final publicKey = privateKey.getPublicKey();
    final identityPrivate = PrivateKey.deserialize(
      bytes: identityKeyPair.privateKey.toList(),
    );
    final signature = identityPrivate.sign(
      message: publicKey.serialize().toList(),
    );
    final record = SignedPreKeyRecord(
      id: id,
      timestamp: BigInt.from(nowMs ?? DateTime.now().millisecondsSinceEpoch),
      publicKey: publicKey,
      privateKey: privateKey,
      signature: signature,
    );
    await store.storeSignedPreKey(id, record);
  }

  Future<void> _ensureKyberPreKey(
    String uid,
    IdentityKeyPair identityKeyPair, {
    int? nowMs,
  }) async {
    final store = await getStore(uid);
    final existing = await store.getAllKyberPreKeyIds();
    if (existing.isNotEmpty) {
      return;
    }
    const int id = 1;
    final keyPair = KyberKeyPair.generate();
    final identityPrivate = PrivateKey.deserialize(
      bytes: identityKeyPair.privateKey.toList(),
    );
    final signature = identityPrivate.sign(
      message: keyPair.getPublicKey().serialize().toList(),
    );
    final record = KyberPreKeyRecord.create(
      id: id,
      timestamp: BigInt.from(nowMs ?? DateTime.now().millisecondsSinceEpoch),
      keyPair: keyPair,
      signature: signature,
    );
    await store.storeKyberPreKey(id, record);
  }

  Future<void> _refillPreKeysIfNeeded(
    String uid, {
    IdentityKeyPair? identityKeyPair,
  }) async {
    final store = await getStore(uid);
    final existingIds = await store.getAllPreKeyIds();
    if (existingIds.length >= _preKeyRefillThreshold) {
      return;
    }

    final startingId = existingIds.isEmpty ? 1 : existingIds.reduce(max) + 1;
    final identity = identityKeyPair ?? await store.getIdentityKeyPair();
    final now = DateTime.now().millisecondsSinceEpoch;

    for (var offset = 0; offset < _preKeyBatchSize; offset++) {
      final preKeyId = startingId + offset;
      final privateKey = PrivateKey.generate();
      final record = PreKeyRecord(
        id: preKeyId,
        publicKey: privateKey.getPublicKey(),
        privateKey: privateKey,
      );
      await _cacheService.storePreKey(
        userId: uid,
        preKeyId: preKeyId,
        record: record.serialize(),
        uploaded: false,
      );
    }

    await _ensureSignedPreKey(uid, identity, nowMs: now);
    await _ensureKyberPreKey(uid, identity, nowMs: now);
  }

  int _timestampMs(dynamic value) {
    if (value is Timestamp) return value.millisecondsSinceEpoch;
    if (value is DateTime) return value.millisecondsSinceEpoch;
    if (value is int) return value;
    return 0;
  }

  Uint8List _blob(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    return Uint8List(0);
  }

  Map<String, dynamic> _encodeBlobRow(Map<String, dynamic> row) {
    final encoded = <String, dynamic>{};
    for (final entry in row.entries) {
      final value = entry.value;
      if (value is Uint8List) {
        encoded[entry.key] = base64Encode(value);
      } else if (value is List<int>) {
        encoded[entry.key] = base64Encode(value);
      } else {
        encoded[entry.key] = value;
      }
    }
    return encoded;
  }

  Map<String, dynamic> _decodeSignalState(Map<String, dynamic> payload) {
    Map<String, dynamic> decodeMap(Map<String, dynamic> row) {
      final decoded = <String, dynamic>{};
      for (final entry in row.entries) {
        final value = entry.value;
        if (value is String &&
            const {
              'identity_key_pair',
              'identity_key',
              'record',
            }.contains(entry.key)) {
          decoded[entry.key] = base64Decode(value);
        } else {
          decoded[entry.key] = value;
        }
      }
      return decoded;
    }

    final decoded = <String, dynamic>{};
    final identity = payload['identity'];
    if (identity is Map<String, dynamic>) {
      decoded['identity'] = decodeMap(identity);
    }
    for (final key in const [
      'remoteIdentities',
      'sessions',
      'preKeys',
      'signedPreKeys',
      'kyberPreKeys',
    ]) {
      final list = payload[key] as List<dynamic>? ?? const [];
      decoded[key] = list
          .whereType<Map<String, dynamic>>()
          .map(decodeMap)
          .toList(growable: false);
    }
    return decoded;
  }
}
