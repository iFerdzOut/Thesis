import 'package:cloud_firestore/cloud_firestore.dart';

class EncryptedMessageModel {
  final String messageId;
  final String conversationId;
  final String clientMessageId;
  final String senderId;
  final String receiverId;
  final String senderDeviceDocId;
  final String receiverDeviceDocId;
  final int senderSignalDeviceId;
  final int receiverSignalDeviceId;
  final String cipherText;
  final int signalMessageType;
  final String algorithm;
  final int protocolVersion;
  final String type;
  final String text;
  final String fileName;
  final String fileSize;
  final bool e2ee;
  final bool e2eeMedia;
  final bool isSuspicious;
  final bool isDeleted;
  final bool isRead;
  final int editCount;
  final Timestamp? timestamp;
  final String? cacheKey;
  final String? senderPublicKey;
  final String? receiverPublicKey;
  final String? sessionId;
  final int? preKeyIdUsed;
  final int? signedPreKeyIdUsed;

  const EncryptedMessageModel({
    required this.messageId,
    required this.conversationId,
    required this.clientMessageId,
    required this.senderId,
    required this.receiverId,
    required this.senderDeviceDocId,
    required this.receiverDeviceDocId,
    required this.senderSignalDeviceId,
    required this.receiverSignalDeviceId,
    required this.cipherText,
    required this.signalMessageType,
    required this.algorithm,
    required this.protocolVersion,
    required this.type,
    required this.text,
    required this.fileName,
    required this.fileSize,
    required this.e2ee,
    required this.e2eeMedia,
    required this.isSuspicious,
    required this.isDeleted,
    required this.isRead,
    required this.editCount,
    required this.timestamp,
    required this.cacheKey,
    required this.senderPublicKey,
    required this.receiverPublicKey,
    required this.sessionId,
    required this.preKeyIdUsed,
    required this.signedPreKeyIdUsed,
  });

  factory EncryptedMessageModel.fromFirestore({
    required String conversationId,
    required String messageId,
    required Map<String, dynamic> data,
  }) {
    return EncryptedMessageModel(
      messageId: messageId,
      conversationId: conversationId,
      clientMessageId: data['clientMessageId']?.toString() ?? messageId,
      senderId: data['senderId']?.toString() ?? '',
      receiverId: data['receiverId']?.toString() ?? '',
      senderDeviceDocId: data['senderDeviceDocId']?.toString() ?? '',
      receiverDeviceDocId: data['receiverDeviceDocId']?.toString() ?? '',
      senderSignalDeviceId:
          (data['senderSignalDeviceId'] as num?)?.toInt() ?? 1,
      receiverSignalDeviceId:
          (data['receiverSignalDeviceId'] as num?)?.toInt() ?? 1,
      cipherText: data['cipherText']?.toString() ?? '',
      signalMessageType: (data['e2eeMessageType'] as num?)?.toInt() ?? 0,
      algorithm: data['e2eeAlgorithm']?.toString() ?? '',
      protocolVersion: (data['e2eeProtocolVersion'] as num?)?.toInt() ?? 1,
      type: data['type']?.toString() ?? 'text',
      text: data['text']?.toString() ?? '',
      fileName: data['fileName']?.toString() ?? '',
      fileSize: data['fileSize']?.toString() ?? '',
      e2ee: data['e2ee'] == true,
      e2eeMedia: data['e2eeMedia'] == true,
      isSuspicious: data['isSuspicious'] == true,
      isDeleted: data['isDeleted'] == true || data['type'] == 'deleted',
      isRead: data['isRead'] == true,
      editCount: (data['editCount'] as num?)?.toInt() ?? 0,
      timestamp: data['timestamp'] as Timestamp?,
      cacheKey: data['e2eeCacheKey']?.toString(),
      senderPublicKey: data['senderPublicKey']?.toString(),
      receiverPublicKey: data['receiverPublicKey']?.toString(),
      sessionId: data['e2eeSessionId']?.toString(),
      preKeyIdUsed: (data['e2eePreKeyIdUsed'] as num?)?.toInt(),
      signedPreKeyIdUsed: (data['e2eeSignedPreKeyIdUsed'] as num?)?.toInt(),
    );
  }
}
