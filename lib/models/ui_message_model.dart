import 'safety_status.dart';

class MessageModel {
  final String text;
  final bool isMe;
  final DateTime time;
  final bool isSuspicious;
  final String type;
  final String? filePath;
  final int? providerId;
  final String? providerThreadId;
  final String? messageKey;
  final double? riskScore;
  final String? riskLevel;
  final List<String> detectionReasons;
  final double? modelScore;
  final double? heuristicScore;
  final String? detectionSource;
  final String? pipelineStage;
  final String? detectionDecision;
  final List<String> extractedUrls;
  final String? primaryUrl;
  final String? primaryDomain;
  final bool needsRescan;
  final SafetyStatus safetyStatus;
  final bool isForwarded;

  MessageModel({
    required this.text,
    required this.isMe,
    required this.time,
    this.isSuspicious = false,
    this.type = 'text',
    this.filePath,
    this.providerId,
    this.providerThreadId,
    this.messageKey,
    this.riskScore,
    this.riskLevel,
    this.detectionReasons = const <String>[],
    this.modelScore,
    this.heuristicScore,
    this.detectionSource,
    this.pipelineStage,
    this.detectionDecision,
    this.extractedUrls = const <String>[],
    this.primaryUrl,
    this.primaryDomain,
    this.needsRescan = false,
    this.safetyStatus = SafetyStatus.safe,
    this.isForwarded = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'text': text,
      'isMe': isMe,
      'time': time.toIso8601String(),
      'isSuspicious': isSuspicious,
      'type': type,
      'filePath': filePath,
      'providerId': providerId,
      'providerThreadId': providerThreadId,
      'messageKey': messageKey,
      'riskScore': riskScore,
      'riskLevel': riskLevel,
      'detectionReasons': detectionReasons,
      'modelScore': modelScore,
      'heuristicScore': heuristicScore,
      'detectionSource': detectionSource,
      'pipelineStage': pipelineStage,
      'detectionDecision': detectionDecision,
      'extractedUrls': extractedUrls,
      'primaryUrl': primaryUrl,
      'primaryDomain': primaryDomain,
      'needsRescan': needsRescan,
      'safetyStatus': safetyStatus.value,
      'isForwarded': isForwarded,
    };
  }

  factory MessageModel.fromMap(Map<String, dynamic> map) {
    return MessageModel(
      text: map['text'] ?? '',
      isMe: map['isMe'] ?? false,
      time: DateTime.tryParse(map['time'] ?? '') ?? DateTime.now(),
      isSuspicious: map['isSuspicious'] ?? false,
      type: map['type'] ?? 'text',
      filePath: map['filePath'],
      providerId: (map['providerId'] as num?)?.toInt(),
      providerThreadId: map['providerThreadId']?.toString(),
      messageKey: map['messageKey']?.toString(),
      riskScore: (map['riskScore'] as num?)?.toDouble(),
      riskLevel: map['riskLevel']?.toString(),
      detectionReasons:
          (map['detectionReasons'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => item.toString())
              .where((item) => item.trim().isNotEmpty)
              .toList(),
      modelScore: (map['modelScore'] as num?)?.toDouble(),
      heuristicScore: (map['heuristicScore'] as num?)?.toDouble(),
      detectionSource: map['detectionSource']?.toString(),
      pipelineStage: map['pipelineStage']?.toString(),
      detectionDecision: map['detectionDecision']?.toString(),
      extractedUrls:
          (map['extractedUrls'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => item.toString())
              .where((item) => item.trim().isNotEmpty)
              .toList(),
      primaryUrl: map['primaryUrl']?.toString(),
      primaryDomain: map['primaryDomain']?.toString(),
      needsRescan: map['needsRescan'] == true,
      safetyStatus: SafetyStatus.fromValue(map['safetyStatus']?.toString()),
      isForwarded: map['isForwarded'] == true,
    );
  }
}
