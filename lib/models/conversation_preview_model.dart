import 'decrypted_conversation_message.dart';

class ConversationPreviewModel {
  final String conversationId;
  final String? lastMessageId;
  final String previewText;
  final String previewType;
  final ConversationDecryptionStatus decryptionStatus;
  final DateTime updatedAt;

  const ConversationPreviewModel({
    required this.conversationId,
    required this.lastMessageId,
    required this.previewText,
    required this.previewType,
    required this.decryptionStatus,
    required this.updatedAt,
  });

  factory ConversationPreviewModel.fromCacheRow(Map<String, dynamic> row) {
    final updatedAtMs =
        (row['updated_at'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    return ConversationPreviewModel(
      conversationId: row['conversation_id']?.toString() ?? '',
      lastMessageId: row['last_message_id']?.toString(),
      previewText: row['preview_text']?.toString() ?? 'Encrypted message',
      previewType: row['preview_type']?.toString() ?? 'text',
      decryptionStatus: ConversationDecryptionStatus.fromValue(
        row['decryption_status']?.toString(),
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
    );
  }
}
