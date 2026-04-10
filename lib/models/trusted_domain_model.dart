class TrustedDomainModel {
  final String domain;
  final String source;
  final String? note;
  final int createdAtMs;
  final int updatedAtMs;

  const TrustedDomainModel({
    required this.domain,
    required this.source,
    required this.note,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'domain': domain,
      'source': source,
      'note': note,
      'createdAtMs': createdAtMs,
      'updatedAtMs': updatedAtMs,
    };
  }

  factory TrustedDomainModel.fromMap(Map<String, dynamic> map) {
    return TrustedDomainModel(
      domain: map['domain']?.toString() ?? '',
      source: map['source']?.toString() ?? 'seed',
      note: map['note']?.toString(),
      createdAtMs: (map['createdAtMs'] as num?)?.toInt() ??
          (map['created_at'] as num?)?.toInt() ??
          0,
      updatedAtMs: (map['updatedAtMs'] as num?)?.toInt() ??
          (map['updated_at'] as num?)?.toInt() ??
          0,
    );
  }
}
