import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:libsignal/libsignal.dart';
import 'package:uuid/uuid.dart';

import '../models/prekey_bundle_model.dart';
import 'libsignal_store_service.dart';
import 'local_message_cache_service.dart';

class KeyManagementService {
  KeyManagementService._internal();

  static final KeyManagementService _instance =
      KeyManagementService._internal();
  factory KeyManagementService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final LocalMessageCacheService _cacheService = LocalMessageCacheService();
  final Uuid _uuid = const Uuid();
  final Random _random = Random.secure();

  Future<void>? _initFuture;
  String? _initializedUserId;

  // Coalesces concurrent ensureDeviceIdentity calls for the same uid so that
  // _publishPublicBundle (and its stale-doc retirement batch) only runs once
  // even when multiple callers race at startup.
  final Map<String, Future<void>> _pendingEnsureIdentity =
      <String, Future<void>>{};

  // Short-lived cache for peer device bundles (no OTK consumed).
  // Avoids a Firestore devices-collection read on every consecutive send
  // to the same peer when the Signal session is already established.
  final Map<String, List<PreKeyBundleModel>> _bundleCache =
      <String, List<PreKeyBundleModel>>{};
  final Map<String, DateTime> _bundleCacheTime = <String, DateTime>{};
  static const Duration _bundleCacheTtl = Duration(seconds: 5);

  static const int _defaultSignalDeviceId = 1;
  static const int _protocolVersion = 2;
  static const int _preKeyBatchSize = 40;
  static const int _preKeyRefillThreshold = 20;
  static const int _signedPreKeyRotationDays = 15;

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

    // Coalesce concurrent non-forced calls for the same uid so that
    // _publishPublicBundle (and its stale-doc retirement batch) only runs once.
    if (!forceRepublish) {
      final pending = _pendingEnsureIdentity[uid];
      if (pending != null) return pending;
      final future = () async {
        try {
          await _doEnsureDeviceIdentity(uid: uid);
        } finally {
          _pendingEnsureIdentity.remove(uid);
        }
      }();
      _pendingEnsureIdentity[uid] = future;
      return future;
    }

    return _doEnsureDeviceIdentity(uid: uid, forceRepublish: true);
  }

  Future<void> _doEnsureDeviceIdentity({
    required String uid,
    bool forceRepublish = false,
  }) async {
    var requiresRepublish = forceRepublish;

    if (!requiresRepublish && _initializedUserId == uid) {
      final hasDoc = await hasActiveDeviceDocuments(uid);
      if (!hasDoc) {
        debugPrint(
          '[KeyMgmt] In-memory marker set for $uid but no active Firestore '
          'device doc found — republishing bundle.',
        );
        requiresRepublish = true;
      }
    }

    var identityRow = await _cacheService.readIdentity(uid);
    IdentityKeyPair identityKeyPair;

    if (identityRow == null) {
      identityKeyPair = IdentityKeyPair.generate();
      final registrationId = 1 + _random.nextInt(16380);
      final deviceDocId = _uuid.v4();
      final signalDeviceId = await _reserveUniqueSignalDeviceId(uid);
      await _cacheService.upsertIdentity(
        userId: uid,
        deviceDocId: deviceDocId,
        signalDeviceId: signalDeviceId,
        registrationId: registrationId,
        identityKeyPair: identityKeyPair.serialize(),
      );
      identityRow = await _cacheService.readIdentity(uid);
      if (identityRow == null) {
        throw Exception('Failed to persist Signal identity.');
      }
      requiresRepublish = true;
    } else {
      identityRow = await _repairIdentityBindingIfNeeded(uid, identityRow);
      identityKeyPair = IdentityKeyPair.deserialize(
        bytes: _blob(identityRow['identity_key_pair']).toList(),
      );
    }

    final currentDeviceDocId = identityRow['device_doc_id']?.toString().trim() ?? '';
    if (currentDeviceDocId.isEmpty) {
      throw Exception('Device document ID is missing after identity initialization.');
    }

    // PERF: Stale device cleanup is now handled only within _publishPublicBundle
    // to avoid running a Firestore query on every single message send.
    // await _cleanupStaleDeviceDocuments(uid, currentDeviceDocId);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rotatedSigned = await _ensureSignedPreKey(uid, identityKeyPair, nowMs: nowMs);
    final rotatedKyber = await _ensureKyberPreKey(uid, identityKeyPair, nowMs: nowMs);

    if (rotatedSigned || rotatedKyber) {
      requiresRepublish = true;
    }

    await _refillPreKeysIfNeeded(uid);

    if (requiresRepublish) {
      await _publishPublicBundle(uid);
    } else {
      // Flush newly minted One-Time Pre-Keys if we skipped the full republish
      await _uploadPendingPreKeys(uid);
    }

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

  /// Invalidates the cached device bundle for [peerUserId] so the next call
  /// to [fetchPeerBundles] fetches fresh data from Firestore. Call this when
  /// a session rebuild is forced (e.g. identity changed).
  void invalidateBundleCache(String peerUserId) {
    _bundleCache.remove(peerUserId);
    _bundleCacheTime.remove(peerUserId);
  }

  Future<List<PreKeyBundleModel>> fetchPeerBundles(
    String peerUserId, {
    required bool consumeOneTimePreKey,
  }) async {
    await initialize();
    if (peerUserId.trim().isEmpty) return const <PreKeyBundleModel>[];

    // Return cached bundles when we are only peeking (no OTK consumed) and
    // the cache is still fresh. This avoids a Firestore round-trip on every
    // consecutive message send to the same peer.
    if (!consumeOneTimePreKey) {
      final cached = _bundleCache[peerUserId];
      final cachedAt = _bundleCacheTime[peerUserId];
      if (cached != null &&
          cachedAt != null &&
          DateTime.now().difference(cachedAt) < _bundleCacheTtl) {
        return cached;
      }
    }

    final devicesSnapshot = await _firestore
        .collection('users')
        .doc(peerUserId)
        .collection('devices')
        .where('active', isEqualTo: true)
        .get();
    if (devicesSnapshot.docs.isEmpty) {
      // FIX: If the peer is ourselves (sending to self for multi-device sync)
      // and we have no active device doc, our own bootstrap failed to publish.
      // Re-run it now so the send can succeed instead of throwing.
      if (peerUserId == currentUserId) {
        debugPrint(
          '[KeyMgmt] No active device doc found for self ($peerUserId) — '
          'republishing bundle now.',
        );
        await ensureDeviceIdentity(userId: peerUserId, forceRepublish: true);
        final retrySnapshot = await _firestore
            .collection('users')
            .doc(peerUserId)
            .collection('devices')
            .where('active', isEqualTo: true)
            .get();
        if (retrySnapshot.docs.isEmpty) {
          return const <PreKeyBundleModel>[];
        }
        // Fall through with the repaired snapshot.
        final retryBundles = <PreKeyBundleModel>[];
        for (final deviceDoc in retrySnapshot.docs) {
          final bundle = await _bundleForDeviceDoc(
            peerUserId: peerUserId,
            deviceDoc: deviceDoc,
            consumeOneTimePreKey: consumeOneTimePreKey,
          );
          if (bundle != null) retryBundles.add(bundle);
        }
        return retryBundles;
      }
      return const <PreKeyBundleModel>[];
    }

    final deviceDocs = [...devicesSnapshot.docs]..sort((a, b) {
        final aMs = _timestampMs(a.data()['updatedAt']);
        final bMs = _timestampMs(b.data()['updatedAt']);
        return bMs.compareTo(aMs);
      });

    // FIX: Run all bundle fetches (and OTK consumption transactions) concurrently 
    // rather than sequentially. This drastically reduces network wait time.
    final bundleFutures = deviceDocs.map((deviceDoc) => _bundleForDeviceDoc(
          peerUserId: peerUserId,
          deviceDoc: deviceDoc,
          consumeOneTimePreKey: consumeOneTimePreKey,
        ));
    final fetchedBundles = await Future.wait(bundleFutures);
    final bundles = fetchedBundles.whereType<PreKeyBundleModel>().toList();

    // Cache peek-only results so repeated sends skip the Firestore read.
    if (!consumeOneTimePreKey && bundles.isNotEmpty) {
      _bundleCache[peerUserId] = bundles;
      _bundleCacheTime[peerUserId] = DateTime.now();
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
    if (consumeOneTimePreKey) {
      try {
        oneTimePreKeyData = await _consumeOneTimePreKeyAtomically(
          deviceDoc.reference,
        );
      } catch (e) {
        debugPrint(
          '[KeyMgmt] OTK consumption failed for ${deviceDoc.id}, '
          'proceeding without OTK (Signal X3DH still functional): $e',
        );
        // oneTimePreKeyData stays null — Signal X3DH works without a one-time
        // prekey, providing slightly less forward secrecy on this first message.
      }
    } else {
      final oneTimePreKeySnapshot = await deviceDoc.reference
          .collection('one_time_prekeys')
          .orderBy('preKeyId')
          .limit(1)
          .get();
      if (oneTimePreKeySnapshot.docs.isNotEmpty) {
        oneTimePreKeyData = oneTimePreKeySnapshot.docs.first.data();
      }
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
    _initializedUserId = null;
    await ensureDeviceIdentity(userId: uid, forceRepublish: true);
  }

  Future<bool> hasActiveDeviceDocuments(
    String uid, {
    String? excludingDeviceDocId,
  }) async {
    await initialize();
    if (uid.trim().isEmpty) {
      return false;
    }
    final excluded = excludingDeviceDocId?.trim() ?? '';
    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .where('active', isEqualTo: true)
        .get();
    return snapshot.docs.any((doc) => excluded.isEmpty || doc.id != excluded);
  }

  Future<void> deactivateCurrentDevice({String? userId}) async {
    await initialize();
    final uid = (userId ?? currentUserId).trim();
    if (uid.isEmpty) {
      return;
    }
    final identityRow = await _cacheService.readIdentity(uid);
    final deviceDocId = identityRow?['device_doc_id']?.toString().trim() ?? '';
    if (deviceDocId.isEmpty) {
      _initializedUserId = null;
      return;
    }
    await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .doc(deviceDocId)
        .set({
      'active': false,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    if (_initializedUserId == uid) {
      _initializedUserId = null;
    }
  }

  // ── FIX: Extracted upload helper ─────────────────────────────────────────
  // Previously the OTK upload logic lived only inside _publishPublicBundle,
  // which is only called from ensureDeviceIdentity. This meant newly generated
  // OTKs from _refillPreKeysIfNeeded were stored locally with uploaded:false
  // but never pushed to Firestore until the next full ensureDeviceIdentity call.
  // Now both _publishPublicBundle and _refillPreKeysIfNeeded call this method.
  Future<void> _uploadPendingPreKeys(String uid) async {
    final identityRow = await _cacheService.readIdentity(uid);
    final deviceDocId = identityRow?['device_doc_id']?.toString().trim() ?? '';
    if (deviceDocId.isEmpty) return;

    final deviceRef = _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .doc(deviceDocId);

    final pendingPreKeys = await _cacheService.getPendingPreKeys(uid);
    for (final row in pendingPreKeys) {
      final preKeyId = (row['prekey_id'] as num?)?.toInt() ?? 0;
      final recordBytes = _blob(row['record']);
      final record = PreKeyRecord.deserialize(bytes: recordBytes.toList());
      await deviceRef
          .collection('one_time_prekeys')
          .doc(preKeyId.toString())
          .set({
        'preKeyId': preKeyId,
        'preKeyPublic': base64Encode(record.publicKey()),
        'createdAt': FieldValue.serverTimestamp(),
      });
      await _cacheService.markPreKeyUploaded(userId: uid, preKeyId: preKeyId);
    }

    if (pendingPreKeys.isNotEmpty) {
      // Keep the preKeyCount on the device doc accurate so peers know OTKs exist
      final store = await getStore(uid);
      final currentPreKeyCount = (await store.getAllPreKeyIds()).length;
      await deviceRef.set(
        {
          'preKeyCount': currentPreKeyCount,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
    }
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

    // FIX: delegate to shared upload helper instead of duplicating the loop
    await _uploadPendingPreKeys(uid);

    final pendingKyberKeys = await _cacheService.getPendingKyberPreKeys(uid);
    for (final row in pendingKyberKeys) {
      final preKeyId = (row['prekey_id'] as num?)?.toInt() ?? 0;
      await _cacheService.markKyberPreKeyUploaded(
          userId: uid, preKeyId: preKeyId);
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

    // Retire any stale device documents left over from previous installations.
    // Only the current deviceDocId should remain active; all others have keys
    // that no longer correspond to any local private-key material, causing
    // "invalid signature detected" for peers trying to build sessions and
    // "invalid PreKey message" when their OTKs are consumed but private keys
    // are gone from the receiver's store.
    final staleDocs = await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .where('active', isEqualTo: true)
        .get();
    final staleOthers =
        staleDocs.docs.where((d) => d.id != deviceDocId).toList();
    if (staleOthers.isNotEmpty) {
      final batch = _firestore.batch();
      for (final doc in staleOthers) {
        batch.update(doc.reference, <String, dynamic>{
          'active': false,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      await batch.commit();
      debugPrint(
        '[KeyMgmt] Retired ${staleOthers.length} stale device '
        'doc(s) for $uid',
      );
    }
  }

  Future<int> _reserveUniqueSignalDeviceId(String uid) async {
    final observedMax = await _maxActiveSignalDeviceId(uid);
    final userRef = _firestore.collection('users').doc(uid);
    return _firestore.runTransaction<int>((txn) async {
      final userSnap = await txn.get(userRef);
      final storedNext =
          (userSnap.data()?['nextSignalDeviceId'] as num?)?.toInt() ??
              _defaultSignalDeviceId;
      final nextSignalDeviceId =
          max(storedNext, max(observedMax + 1, _defaultSignalDeviceId));
      txn.set(
          userRef,
          {
            'nextSignalDeviceId': nextSignalDeviceId + 1,
          },
          SetOptions(merge: true));
      return nextSignalDeviceId;
    });
  }

  Future<int> _maxActiveSignalDeviceId(String uid) async {
    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .where('active', isEqualTo: true)
        .get();
    var currentMax = 0;
    for (final doc in snapshot.docs) {
      final value = (doc.data()['signalDeviceId'] as num?)?.toInt() ??
          _defaultSignalDeviceId;
      if (value > currentMax) {
        currentMax = value;
      }
    }
    return currentMax;
  }

  Future<Map<String, dynamic>> _repairIdentityBindingIfNeeded(
    String uid,
    Map<String, dynamic> identityRow,
  ) async {
    var deviceDocId = identityRow['device_doc_id']?.toString().trim() ?? '';
    var signalDeviceId = (identityRow['signal_device_id'] as num?)?.toInt() ??
        _defaultSignalDeviceId;
    var registrationId = (identityRow['registration_id'] as num?)?.toInt() ?? 0;
    var changed = false;

    if (deviceDocId.isEmpty) {
      deviceDocId = _uuid.v4();
      changed = true;
    }
    if (registrationId <= 0) {
      registrationId = 1 + _random.nextInt(16380);
      changed = true;
    }
    if (signalDeviceId <= 0 ||
        await _isSignalDeviceIdInUse(
          uid,
          signalDeviceId: signalDeviceId,
          excludingDeviceDocId: deviceDocId,
        )) {
      signalDeviceId = await _reserveUniqueSignalDeviceId(uid);
      changed = true;
    }

    if (!changed) {
      return identityRow;
    }

    await _cacheService.updateIdentityDeviceBinding(
      userId: uid,
      deviceDocId: deviceDocId,
      signalDeviceId: signalDeviceId,
      registrationId: registrationId,
    );
    return (await _cacheService.readIdentity(uid)) ?? identityRow;
  }

  Future<bool> _isSignalDeviceIdInUse(
    String uid, {
    required int signalDeviceId,
    required String excludingDeviceDocId,
  }) async {
    final snapshot = await _firestore
        .collection('users')
        .doc(uid)
        .collection('devices')
        .where('active', isEqualTo: true)
        .where('signalDeviceId', isEqualTo: signalDeviceId)
        .get();
    return snapshot.docs.any((doc) => doc.id != excludingDeviceDocId);
  }

  Future<Map<String, dynamic>?> _consumeOneTimePreKeyAtomically(
    DocumentReference<Map<String, dynamic>> deviceRef,
  ) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final snapshot = await deviceRef
          .collection('one_time_prekeys')
          .orderBy('preKeyId')
          .limit(1)
          .get();
      if (snapshot.docs.isEmpty) {
        return null;
      }

      final candidateRef = snapshot.docs.first.reference;
      final reserved = await _firestore.runTransaction<Map<String, dynamic>?>(
        (txn) async {
          final candidateSnap = await txn.get(candidateRef);
          if (!candidateSnap.exists) {
            return null;
          }
          final data = candidateSnap.data();
          if (data == null) {
            return null;
          }
          txn.delete(candidateRef);
          return data;
        },
      );
      if (reserved != null) {
        return reserved;
      }
    }
    return null;
  }

  Future<bool> _ensureSignedPreKey(
    String uid,
    IdentityKeyPair identityKeyPair, {
    int? nowMs,
  }) async {
    final store = await getStore(uid);
    final existing = await store.getAllSignedPreKeyIds();
    
    int nextId = 1;
    if (existing.isNotEmpty) {
      final latestId = existing.reduce(max);
      final latestRecord = await store.loadSignedPreKey(latestId);
      if (latestRecord != null) {
        final timestampMs = latestRecord.timestamp().toInt();
        final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestampMs));
        if (age.inDays < _signedPreKeyRotationDays) {
          return false; // Current Signed Pre-Key is still fresh
        }
        debugPrint('[KeyMgmt] Rotating Signed Pre-Key for $uid (age: ${age.inDays} days)');
      }
      nextId = latestId + 1;
    }
    
    final privateKey = PrivateKey.generate();
    final publicKey = privateKey.getPublicKey();
    final identityPrivate = PrivateKey.deserialize(
      bytes: identityKeyPair.privateKey.toList(),
    );
    final signature = identityPrivate.sign(
      message: publicKey.serialize().toList(),
    );
    final record = SignedPreKeyRecord(
      id: nextId,
      timestamp: BigInt.from(nowMs ?? DateTime.now().millisecondsSinceEpoch),
      publicKey: publicKey,
      privateKey: privateKey,
      signature: signature,
    );
    await store.storeSignedPreKey(nextId, record);
    return true;
  }

  Future<bool> _ensureKyberPreKey(
    String uid,
    IdentityKeyPair identityKeyPair, {
    int? nowMs,
  }) async {
    final store = await getStore(uid);
    final existing = await store.getAllKyberPreKeyIds();
    
    int nextId = 1;
    if (existing.isNotEmpty) {
      final latestId = existing.reduce(max);
      final latestRecord = await store.loadKyberPreKey(latestId);
      if (latestRecord != null) {
        final timestampMs = latestRecord.timestamp().toInt();
        final age = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(timestampMs));
        if (age.inDays < _signedPreKeyRotationDays) {
          return false; // Current Kyber Pre-Key is still fresh
        }
      }
      nextId = latestId + 1;
    }
    final keyPair = KyberKeyPair.generate();
    final identityPrivate = PrivateKey.deserialize(
      bytes: identityKeyPair.privateKey.toList(),
    );
    final signature = identityPrivate.sign(
      message: keyPair.getPublicKey().serialize().toList(),
    );
    final record = KyberPreKeyRecord.create(
      id: nextId,
      timestamp: BigInt.from(nowMs ?? DateTime.now().millisecondsSinceEpoch),
      keyPair: keyPair,
      signature: signature,
    );
    await store.storeKyberPreKey(nextId, record);
    return true;
  }

  Future<void> _refillPreKeysIfNeeded(String uid) async {
    final store = await getStore(uid);
    final existingIds = await store.getAllPreKeyIds();
    if (existingIds.length >= _preKeyRefillThreshold) {
      return;
    }

    final startingId = existingIds.isEmpty ? 1 : existingIds.reduce(max) + 1;

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