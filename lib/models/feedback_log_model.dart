class FeedbackLogModel {
  final String messageKey;
  final String label;
  final String source;
  final String sender;
  final String? primaryDomain;
  final double? riskScore;
  final String? notes;
  final int createdAtMs;

  const FeedbackLogModel({
    required this.messageKey,
    required this.label,
    required this.source,
    required this.sender,
    required this.primaryDomain,
    required this.riskScore,
    required this.notes,
    required this.createdAtMs,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'messageKey': messageKey,
      'label': label,
      'source': source,
      'sender': sender,
      'primaryDomain': primaryDomain,
      'riskScore': riskScore,
      'notes': notes,
      'createdAtMs': createdAtMs,
    };
  }

  factory FeedbackLogModel.fromMap(Map<String, dynamic> map) {
    return FeedbackLogModel(
      messageKey: map['messageKey']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      source: map['source']?.toString() ?? '',
      sender: map['sender']?.toString() ?? '',
      primaryDomain: map['primaryDomain']?.toString(),
      riskScore: (map['riskScore'] as num?)?.toDouble(),
      notes: map['notes']?.toString(),
      createdAtMs: (map['createdAtMs'] as num?)?.toInt() ??
          (map['created_at'] as num?)?.toInt() ??
          0,
    );
  }
}
