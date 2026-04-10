enum ConversationDecryptionStatus {
  pending,
  success,
  failed;

  String get value => name;

  static ConversationDecryptionStatus fromValue(String? value) {
    switch (value?.trim()) {
      case 'success':
        return ConversationDecryptionStatus.success;
      case 'failed':
        return ConversationDecryptionStatus.failed;
      case 'pending':
      default:
        return ConversationDecryptionStatus.pending;
    }
  }
}

class DecryptedConversationMessage {
  final String conversationId;
  final String messageKey;
  final String? messageId;
  final String? clientMessageId;
  final String senderId;
  final String receiverId;
  final String messageType;
  final String? algorithm;
  final bool cipherTextPresent;
  final String? decryptedText;
  final String previewText;
  final ConversationDecryptionStatus decryptionStatus;
  final String? failureReason;
  final DateTime timestamp;
  final bool isOutgoing;
  final bool isDeleted;
  final bool isSuspicious;

  const DecryptedConversationMessage({
    required this.conversationId,
    required this.messageKey,
    required this.messageId,
    required this.clientMessageId,
    required this.senderId,
    required this.receiverId,
    required this.messageType,
    required this.algorithm,
    required this.cipherTextPresent,
    required this.decryptedText,
    required this.previewText,
    required this.decryptionStatus,
    required this.failureReason,
    required this.timestamp,
    required this.isOutgoing,
    required this.isDeleted,
    required this.isSuspicious,
  });

  factory DecryptedConversationMessage.fromCacheRow(
    Map<String, dynamic> row, {
    required String currentUserId,
  }) {
    final timestampMs = (row['message_timestamp_ms'] as num?)?.toInt() ??
        (row['updated_at'] as num?)?.toInt() ??
        0;
    final senderId = row['sender_id']?.toString() ?? '';
    final rawPlaintext = row['plaintext']?.toString();
    final plaintext =
        (rawPlaintext == null || rawPlaintext.isEmpty) ? null : rawPlaintext;
    return DecryptedConversationMessage(
      conversationId: row['conversation_id']?.toString() ?? '',
      messageKey: row['message_key']?.toString() ?? '',
      messageId: row['message_id']?.toString(),
      clientMessageId: row['client_message_id']?.toString(),
      senderId: senderId,
      receiverId: row['receiver_id']?.toString() ?? '',
      messageType: row['message_type']?.toString() ?? 'text',
      algorithm: row['algorithm']?.toString(),
      cipherTextPresent: row['cipher_text_present'] == 1,
      decryptedText: plaintext,
      previewText: row['preview_text']?.toString() ?? plaintext ?? '',
      decryptionStatus: ConversationDecryptionStatus.fromValue(
        row['decryption_status']?.toString(),
      ),
      failureReason: row['failure_reason']?.toString(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      isOutgoing: senderId == currentUserId,
      isDeleted: row['is_deleted'] == 1,
      isSuspicious: row['is_suspicious'] == 1,
    );
  }
}
