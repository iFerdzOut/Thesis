import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:libsignal/libsignal.dart';

class PreKeyBundleModel {
  final String userId;
  final String deviceDocId;
  final int signalDeviceId;
  final int registrationId;
  final String identityPublicKeyBase64;
  final int signedPreKeyId;
  final String signedPreKeyPublicBase64;
  final String signedPreKeySignatureBase64;
  final int kyberPreKeyId;
  final String kyberPreKeyPublicBase64;
  final String kyberPreKeySignatureBase64;
  final int? oneTimePreKeyId;
  final String? oneTimePreKeyPublicBase64;
  final int protocolVersion;
  final bool active;
  final int updatedAtMs;

  const PreKeyBundleModel({
    required this.userId,
    required this.deviceDocId,
    required this.signalDeviceId,
    required this.registrationId,
    required this.identityPublicKeyBase64,
    required this.signedPreKeyId,
    required this.signedPreKeyPublicBase64,
    required this.signedPreKeySignatureBase64,
    required this.kyberPreKeyId,
    required this.kyberPreKeyPublicBase64,
    required this.kyberPreKeySignatureBase64,
    required this.oneTimePreKeyId,
    required this.oneTimePreKeyPublicBase64,
    required this.protocolVersion,
    required this.active,
    required this.updatedAtMs,
  });

  factory PreKeyBundleModel.fromFirestore({
    required String userId,
    required String deviceDocId,
    required Map<String, dynamic> deviceData,
    Map<String, dynamic>? oneTimePreKeyData,
  }) {
    final updatedAt = deviceData['updatedAt'];
    final updatedAtMs = updatedAt is Timestamp
        ? updatedAt.millisecondsSinceEpoch
        : updatedAt is DateTime
            ? updatedAt.millisecondsSinceEpoch
            : updatedAt is int
                ? updatedAt
                : 0;

    return PreKeyBundleModel(
      userId: userId,
      deviceDocId: deviceDocId,
      signalDeviceId: (deviceData['signalDeviceId'] as num?)?.toInt() ?? 1,
      registrationId: (deviceData['registrationId'] as num?)?.toInt() ?? 0,
      identityPublicKeyBase64:
          deviceData['identityPublicKey']?.toString() ?? '',
      signedPreKeyId: (deviceData['signedPreKeyId'] as num?)?.toInt() ?? 0,
      signedPreKeyPublicBase64:
          deviceData['signedPreKeyPublic']?.toString() ?? '',
      signedPreKeySignatureBase64:
          deviceData['signedPreKeySignature']?.toString() ?? '',
      kyberPreKeyId: (deviceData['kyberPreKeyId'] as num?)?.toInt() ?? 0,
      kyberPreKeyPublicBase64:
          deviceData['kyberPreKeyPublic']?.toString() ?? '',
      kyberPreKeySignatureBase64:
          deviceData['kyberPreKeySignature']?.toString() ?? '',
      oneTimePreKeyId: (oneTimePreKeyData?['preKeyId'] as num?)?.toInt(),
      oneTimePreKeyPublicBase64:
          oneTimePreKeyData?['preKeyPublic']?.toString(),
      protocolVersion: (deviceData['protocolVersion'] as num?)?.toInt() ?? 2,
      active: deviceData['active'] != false,
      updatedAtMs: updatedAtMs,
    );
  }

  Map<String, dynamic> toDeviceFirestore() {
    return {
      'signalDeviceId': signalDeviceId,
      'registrationId': registrationId,
      'identityPublicKey': identityPublicKeyBase64,
      'signedPreKeyId': signedPreKeyId,
      'signedPreKeyPublic': signedPreKeyPublicBase64,
      'signedPreKeySignature': signedPreKeySignatureBase64,
      'kyberPreKeyId': kyberPreKeyId,
      'kyberPreKeyPublic': kyberPreKeyPublicBase64,
      'kyberPreKeySignature': kyberPreKeySignatureBase64,
      'protocolVersion': protocolVersion,
      'active': active,
      'updatedAt': updatedAtMs,
    };
  }

  Map<String, dynamic> toOneTimePreKeyFirestore() {
    return {
      'preKeyId': oneTimePreKeyId,
      'preKeyPublic': oneTimePreKeyPublicBase64,
      'createdAt': updatedAtMs,
    };
  }

  ProtocolAddress toProtocolAddress() {
    return ProtocolAddress(name: userId, deviceId: signalDeviceId);
  }

  PreKeyBundle toSignalPreKeyBundle() {
    return PreKeyBundle(
      registrationId: registrationId,
      deviceId: signalDeviceId,
      preKeyId: oneTimePreKeyId,
      preKeyPublic: oneTimePreKeyPublicBase64 == null
          ? null
          : _decode(oneTimePreKeyPublicBase64!),
      signedPreKeyId: signedPreKeyId,
      signedPreKeyPublic: _decode(signedPreKeyPublicBase64),
      signedPreKeySignature: _decode(signedPreKeySignatureBase64),
      identityKey: _decode(identityPublicKeyBase64),
      kyberPreKeyId: kyberPreKeyId,
      kyberPreKeyPublic: _decode(kyberPreKeyPublicBase64),
      kyberPreKeySignature: _decode(kyberPreKeySignatureBase64),
    );
  }

  Map<String, dynamic> toBackupMap() {
    return {
      'userId': userId,
      'deviceDocId': deviceDocId,
      'signalDeviceId': signalDeviceId,
      'registrationId': registrationId,
      'identityPublicKeyBase64': identityPublicKeyBase64,
      'signedPreKeyId': signedPreKeyId,
      'signedPreKeyPublicBase64': signedPreKeyPublicBase64,
      'signedPreKeySignatureBase64': signedPreKeySignatureBase64,
      'kyberPreKeyId': kyberPreKeyId,
      'kyberPreKeyPublicBase64': kyberPreKeyPublicBase64,
      'kyberPreKeySignatureBase64': kyberPreKeySignatureBase64,
      'oneTimePreKeyId': oneTimePreKeyId,
      'oneTimePreKeyPublicBase64': oneTimePreKeyPublicBase64,
      'protocolVersion': protocolVersion,
      'active': active,
      'updatedAtMs': updatedAtMs,
    };
  }

  factory PreKeyBundleModel.fromBackupMap(Map<String, dynamic> map) {
    return PreKeyBundleModel(
      userId: map['userId']?.toString() ?? '',
      deviceDocId: map['deviceDocId']?.toString() ?? '',
      signalDeviceId: (map['signalDeviceId'] as num?)?.toInt() ?? 1,
      registrationId: (map['registrationId'] as num?)?.toInt() ?? 0,
      identityPublicKeyBase64: map['identityPublicKeyBase64']?.toString() ?? '',
      signedPreKeyId: (map['signedPreKeyId'] as num?)?.toInt() ?? 0,
      signedPreKeyPublicBase64:
          map['signedPreKeyPublicBase64']?.toString() ?? '',
      signedPreKeySignatureBase64:
          map['signedPreKeySignatureBase64']?.toString() ?? '',
      kyberPreKeyId: (map['kyberPreKeyId'] as num?)?.toInt() ?? 0,
      kyberPreKeyPublicBase64:
          map['kyberPreKeyPublicBase64']?.toString() ?? '',
      kyberPreKeySignatureBase64:
          map['kyberPreKeySignatureBase64']?.toString() ?? '',
      oneTimePreKeyId: (map['oneTimePreKeyId'] as num?)?.toInt(),
      oneTimePreKeyPublicBase64:
          map['oneTimePreKeyPublicBase64']?.toString(),
      protocolVersion: (map['protocolVersion'] as num?)?.toInt() ?? 2,
      active: map['active'] != false,
      updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  Uint8List _decode(String value) => Uint8List.fromList(base64Decode(value));
}
