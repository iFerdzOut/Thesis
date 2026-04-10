import 'dart:typed_data';

import 'package:libsignal/libsignal.dart';

import 'local_message_cache_service.dart';

class LibsignalStoreService
    implements
        IdentityKeyStore,
        SessionStore,
        PreKeyStore,
        SignedPreKeyStore,
        KyberPreKeyStore {
  LibsignalStoreService({
    required this.userId,
    required LocalMessageCacheService cacheService,
  }) : _cacheService = cacheService;

  final String userId;
  final LocalMessageCacheService _cacheService;

  String _peerName(ProtocolAddress address) => address.name();

  int _deviceId(ProtocolAddress address) => address.deviceId();

  Future<Map<String, dynamic>> _readIdentityRow() async {
    final row = await _cacheService.readIdentity(userId);
    if (row == null) {
      throw Exception('Signal identity is not initialized.');
    }
    return row;
  }

  @override
  Future<IdentityKeyPair> getIdentityKeyPair() async {
    final row = await _readIdentityRow();
    final bytes = row['identity_key_pair'];
    if (bytes is Uint8List) {
      return IdentityKeyPair.deserialize(bytes: bytes.toList());
    }
    if (bytes is List<int>) {
      return IdentityKeyPair.deserialize(bytes: bytes);
    }
    throw Exception('Stored identity key pair is invalid.');
  }

  @override
  Future<int> getLocalRegistrationId() async {
    final row = await _readIdentityRow();
    return (row['registration_id'] as num?)?.toInt() ?? 0;
  }

  Future<String> getDeviceDocId() async {
    final row = await _readIdentityRow();
    return row['device_doc_id']?.toString() ?? '';
  }

  Future<int> getSignalDeviceId() async {
    final row = await _readIdentityRow();
    return (row['signal_device_id'] as num?)?.toInt() ?? 1;
  }

  @override
  Future<bool> saveIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
  ) async {
    final existing = await getIdentity(address);
    final changed =
        existing == null || !existing.equals(other: identityKey.cloneKey());
    await _cacheService.saveRemoteIdentity(
      userId: userId,
      peerUid: _peerName(address),
      signalDeviceId: _deviceId(address),
      identityKey: identityKey.serialize(),
    );
    return changed;
  }

  @override
  Future<PublicKey?> getIdentity(ProtocolAddress address) async {
    final bytes = await _cacheService.readRemoteIdentity(
      userId: userId,
      peerUid: _peerName(address),
      signalDeviceId: _deviceId(address),
    );
    if (bytes == null || bytes.isEmpty) return null;
    return PublicKey.deserialize(bytes: bytes.toList());
  }

  @override
  Future<bool> isTrustedIdentity(
    ProtocolAddress address,
    PublicKey identityKey,
    Direction direction,
  ) async {
    final existing = await getIdentity(address);
    if (existing == null) {
      return true;
    }
    return existing.equals(other: identityKey);
  }

  @override
  Future<SessionRecord?> loadSession(ProtocolAddress address) async {
    final bytes = await _cacheService.loadSession(
      userId: userId,
      peerUid: _peerName(address),
      signalDeviceId: _deviceId(address),
    );
    if (bytes == null || bytes.isEmpty) return null;
    return SessionRecord.deserialize(bytes: bytes.toList());
  }

  @override
  Future<void> storeSession(
    ProtocolAddress address,
    SessionRecord record,
  ) async {
    await _cacheService.storeSession(
      userId: userId,
      peerUid: _peerName(address),
      signalDeviceId: _deviceId(address),
      record: record.serialize(),
    );
  }

  @override
  Future<bool> containsSession(ProtocolAddress address) {
    return _cacheService.containsSession(
      userId: userId,
      peerUid: _peerName(address),
      signalDeviceId: _deviceId(address),
    );
  }

  @override
  Future<void> deleteSession(ProtocolAddress address) {
    return _cacheService.deleteSession(
      userId: userId,
      peerUid: _peerName(address),
      signalDeviceId: _deviceId(address),
    );
  }

  @override
  Future<void> deleteAllSessions(String name) {
    return _cacheService.deleteAllSessions(userId: userId, peerUid: name);
  }

  @override
  Future<List<int>> getSubDeviceSessions(String name) {
    return _cacheService.getSessionDeviceIds(userId: userId, peerUid: name);
  }

  @override
  Future<PreKeyRecord?> loadPreKey(int preKeyId) async {
    final bytes = await _cacheService.loadPreKey(
      userId: userId,
      preKeyId: preKeyId,
    );
    if (bytes == null || bytes.isEmpty) return null;
    return PreKeyRecord.deserialize(bytes: bytes.toList());
  }

  @override
  Future<void> storePreKey(int preKeyId, PreKeyRecord record) {
    return _cacheService.storePreKey(
      userId: userId,
      preKeyId: preKeyId,
      record: record.serialize(),
    );
  }

  @override
  Future<bool> containsPreKey(int preKeyId) async {
    final bytes = await _cacheService.loadPreKey(
      userId: userId,
      preKeyId: preKeyId,
    );
    return bytes != null && bytes.isNotEmpty;
  }

  @override
  Future<void> removePreKey(int preKeyId) {
    return _cacheService.removePreKey(userId: userId, preKeyId: preKeyId);
  }

  @override
  Future<List<int>> getAllPreKeyIds() {
    return _cacheService.getAllPreKeyIds(userId);
  }

  @override
  Future<SignedPreKeyRecord?> loadSignedPreKey(int signedPreKeyId) async {
    final bytes = await _cacheService.loadSignedPreKey(
      userId: userId,
      preKeyId: signedPreKeyId,
    );
    if (bytes == null || bytes.isEmpty) return null;
    return SignedPreKeyRecord.deserialize(bytes: bytes.toList());
  }

  @override
  Future<void> storeSignedPreKey(
    int signedPreKeyId,
    SignedPreKeyRecord record,
  ) {
    return _cacheService.storeSignedPreKey(
      userId: userId,
      preKeyId: signedPreKeyId,
      record: record.serialize(),
    );
  }

  @override
  Future<bool> containsSignedPreKey(int signedPreKeyId) async {
    final bytes = await _cacheService.loadSignedPreKey(
      userId: userId,
      preKeyId: signedPreKeyId,
    );
    return bytes != null && bytes.isNotEmpty;
  }

  @override
  Future<void> removeSignedPreKey(int signedPreKeyId) {
    return _cacheService.removeSignedPreKey(
      userId: userId,
      preKeyId: signedPreKeyId,
    );
  }

  @override
  Future<List<int>> getAllSignedPreKeyIds() {
    return _cacheService.getAllSignedPreKeyIds(userId);
  }

  @override
  Future<KyberPreKeyRecord?> loadKyberPreKey(int kyberPreKeyId) async {
    final bytes = await _cacheService.loadKyberPreKey(
      userId: userId,
      preKeyId: kyberPreKeyId,
    );
    if (bytes == null || bytes.isEmpty) return null;
    return KyberPreKeyRecord.deserialize(bytes: bytes.toList());
  }

  @override
  Future<void> storeKyberPreKey(
    int kyberPreKeyId,
    KyberPreKeyRecord record,
  ) {
    return _cacheService.storeKyberPreKey(
      userId: userId,
      preKeyId: kyberPreKeyId,
      record: record.serialize(),
    );
  }

  @override
  Future<bool> containsKyberPreKey(int kyberPreKeyId) async {
    final bytes = await _cacheService.loadKyberPreKey(
      userId: userId,
      preKeyId: kyberPreKeyId,
    );
    return bytes != null && bytes.isNotEmpty;
  }

  @override
  Future<void> markKyberPreKeyUsed(int kyberPreKeyId) {
    return _cacheService.markKyberPreKeyUsed(
      userId: userId,
      preKeyId: kyberPreKeyId,
    );
  }

  @override
  Future<void> removeKyberPreKey(int kyberPreKeyId) {
    return _cacheService.removeKyberPreKey(
      userId: userId,
      preKeyId: kyberPreKeyId,
    );
  }

  @override
  Future<List<int>> getAllKyberPreKeyIds() {
    return _cacheService.getAllKyberPreKeyIds(userId);
  }
}
