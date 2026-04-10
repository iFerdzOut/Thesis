class ScreenedMessageModel {
  final String source;
  final String sender;
  final String? peer;
  final String body;
  final int timestampMs;
  final String messageKey;
  final int? providerId;
  final String? providerThreadId;
  final int? simSlot;
  final int? subscriptionId;

  const ScreenedMessageModel({
    required this.source,
    required this.sender,
    required this.peer,
    required this.body,
    required this.timestampMs,
    required this.messageKey,
    required this.providerId,
    required this.providerThreadId,
    required this.simSlot,
    required this.subscriptionId,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'source': source,
      'sender': sender,
      'peer': peer,
      'body': body,
      'timestampMs': timestampMs,
      'messageKey': messageKey,
      'providerId': providerId,
      'providerThreadId': providerThreadId,
      'simSlot': simSlot,
      'subscriptionId': subscriptionId,
    };
  }

  factory ScreenedMessageModel.fromMap(Map<String, dynamic> map) {
    return ScreenedMessageModel(
      source: map['source']?.toString() ?? 'sms',
      sender: map['sender']?.toString() ?? '',
      peer: map['peer']?.toString(),
      body: map['body']?.toString() ?? '',
      timestampMs: (map['timestampMs'] as num?)?.toInt() ??
          (map['timestamp'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
      messageKey: map['messageKey']?.toString() ?? '',
      providerId: (map['providerId'] as num?)?.toInt(),
      providerThreadId: map['providerThreadId']?.toString() ??
          map['threadId']?.toString(),
      simSlot: (map['simSlot'] as num?)?.toInt(),
      subscriptionId: (map['subscriptionId'] as num?)?.toInt(),
    );
  }

  ScreenedMessageModel copyWith({
    String? source,
    String? sender,
    String? peer,
    String? body,
    int? timestampMs,
    String? messageKey,
    int? providerId,
    String? providerThreadId,
    int? simSlot,
    int? subscriptionId,
  }) {
    return ScreenedMessageModel(
      source: source ?? this.source,
      sender: sender ?? this.sender,
      peer: peer ?? this.peer,
      body: body ?? this.body,
      timestampMs: timestampMs ?? this.timestampMs,
      messageKey: messageKey ?? this.messageKey,
      providerId: providerId ?? this.providerId,
      providerThreadId: providerThreadId ?? this.providerThreadId,
      simSlot: simSlot ?? this.simSlot,
      subscriptionId: subscriptionId ?? this.subscriptionId,
    );
  }
}
