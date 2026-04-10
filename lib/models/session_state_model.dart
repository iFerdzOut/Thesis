class SessionStateModel {
  final String userId;
  final String peerUserId;
  final int signalDeviceId;
  final String peerDeviceDocId;
  final bool hasSession;
  final int updatedAtMs;

  const SessionStateModel({
    required this.userId,
    required this.peerUserId,
    required this.signalDeviceId,
    required this.peerDeviceDocId,
    required this.hasSession,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'peerUserId': peerUserId,
      'signalDeviceId': signalDeviceId,
      'peerDeviceDocId': peerDeviceDocId,
      'hasSession': hasSession,
      'updatedAtMs': updatedAtMs,
    };
  }

  factory SessionStateModel.fromMap(Map<String, dynamic> map) {
    return SessionStateModel(
      userId: map['userId']?.toString() ?? '',
      peerUserId: map['peerUserId']?.toString() ?? '',
      signalDeviceId: (map['signalDeviceId'] as num?)?.toInt() ?? 1,
      peerDeviceDocId: map['peerDeviceDocId']?.toString() ?? '',
      hasSession: map['hasSession'] == true,
      updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}
