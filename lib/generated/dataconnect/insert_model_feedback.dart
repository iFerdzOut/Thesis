// ignore_for_file: non_constant_identifier_names
part of 'smishing_shield_connector.dart';

class InsertModelFeedbackVariablesBuilder {
  String label;
  String aiPrediction;
  String userCorrection;
  String source;
  String senderType;
  String messageSanitized;
  int messageLength;
  bool hasUrl;
  String appVersion;

  final FirebaseDataConnect _dataConnect;
  InsertModelFeedbackVariablesBuilder(this._dataConnect, {required  this.label,required  this.aiPrediction,required  this.userCorrection,required  this.source,required  this.senderType,required  this.messageSanitized,required  this.messageLength,required  this.hasUrl,required  this.appVersion,});
  Deserializer<InsertModelFeedbackData> dataDeserializer = (dynamic json)  => InsertModelFeedbackData.fromJson(jsonDecode(json));
  Serializer<InsertModelFeedbackVariables> varsSerializer = (InsertModelFeedbackVariables vars) => jsonEncode(vars.toJson());
  Future<OperationResult<InsertModelFeedbackData, InsertModelFeedbackVariables>> execute() {
    return ref().execute();
  }

  MutationRef<InsertModelFeedbackData, InsertModelFeedbackVariables> ref() {
    InsertModelFeedbackVariables vars= InsertModelFeedbackVariables(label: label,aiPrediction: aiPrediction,userCorrection: userCorrection,source: source,senderType: senderType,messageSanitized: messageSanitized,messageLength: messageLength,hasUrl: hasUrl,appVersion: appVersion,);
    return _dataConnect.mutation("InsertModelFeedback", dataDeserializer, varsSerializer, vars);
  }
}

@immutable
class InsertModelFeedbackModelFeedbackInsert {
  final String id;
  InsertModelFeedbackModelFeedbackInsert.fromJson(dynamic json):
  
  id = nativeFromJson<String>(json['id']);
  @override
  bool operator ==(Object other) {
    if(identical(this, other)) {
      return true;
    }
    if(other.runtimeType != runtimeType) {
      return false;
    }

    final InsertModelFeedbackModelFeedbackInsert otherTyped = other as InsertModelFeedbackModelFeedbackInsert;
    return id == otherTyped.id;
    
  }
  @override
  int get hashCode => id.hashCode;
  

  Map<String, dynamic> toJson() {
    Map<String, dynamic> json = {};
    json['id'] = nativeToJson<String>(id);
    return json;
  }

  const InsertModelFeedbackModelFeedbackInsert({
    required this.id,
  });
}

@immutable
class InsertModelFeedbackData {
  final InsertModelFeedbackModelFeedbackInsert modelFeedback_insert;
  InsertModelFeedbackData.fromJson(dynamic json):
  
  modelFeedback_insert = InsertModelFeedbackModelFeedbackInsert.fromJson(json['modelFeedback_insert']);
  @override
  bool operator ==(Object other) {
    if(identical(this, other)) {
      return true;
    }
    if(other.runtimeType != runtimeType) {
      return false;
    }

    final InsertModelFeedbackData otherTyped = other as InsertModelFeedbackData;
    return modelFeedback_insert == otherTyped.modelFeedback_insert;
    
  }
  @override
  int get hashCode => modelFeedback_insert.hashCode;
  

  Map<String, dynamic> toJson() {
    Map<String, dynamic> json = {};
    json['modelFeedback_insert'] = modelFeedback_insert.toJson();
    return json;
  }

  const InsertModelFeedbackData({
    required this.modelFeedback_insert,
  });
}

@immutable
class InsertModelFeedbackVariables {
  final String label;
  final String aiPrediction;
  final String userCorrection;
  final String source;
  final String senderType;
  final String messageSanitized;
  final int messageLength;
  final bool hasUrl;
  final String appVersion;
  @Deprecated('fromJson is deprecated for Variable classes as they are no longer required for deserialization.')
  InsertModelFeedbackVariables.fromJson(Map<String, dynamic> json):
  
  label = nativeFromJson<String>(json['label']),
  aiPrediction = nativeFromJson<String>(json['aiPrediction']),
  userCorrection = nativeFromJson<String>(json['userCorrection']),
  source = nativeFromJson<String>(json['source']),
  senderType = nativeFromJson<String>(json['senderType']),
  messageSanitized = nativeFromJson<String>(json['messageSanitized']),
  messageLength = nativeFromJson<int>(json['messageLength']),
  hasUrl = nativeFromJson<bool>(json['hasUrl']),
  appVersion = nativeFromJson<String>(json['appVersion']);
  @override
  bool operator ==(Object other) {
    if(identical(this, other)) {
      return true;
    }
    if(other.runtimeType != runtimeType) {
      return false;
    }

    final InsertModelFeedbackVariables otherTyped = other as InsertModelFeedbackVariables;
    return label == otherTyped.label && 
    aiPrediction == otherTyped.aiPrediction && 
    userCorrection == otherTyped.userCorrection && 
    source == otherTyped.source && 
    senderType == otherTyped.senderType && 
    messageSanitized == otherTyped.messageSanitized && 
    messageLength == otherTyped.messageLength && 
    hasUrl == otherTyped.hasUrl && 
    appVersion == otherTyped.appVersion;
    
  }
  @override
  int get hashCode => Object.hashAll([label.hashCode, aiPrediction.hashCode, userCorrection.hashCode, source.hashCode, senderType.hashCode, messageSanitized.hashCode, messageLength.hashCode, hasUrl.hashCode, appVersion.hashCode]);
  

  Map<String, dynamic> toJson() {
    Map<String, dynamic> json = {};
    json['label'] = nativeToJson<String>(label);
    json['aiPrediction'] = nativeToJson<String>(aiPrediction);
    json['userCorrection'] = nativeToJson<String>(userCorrection);
    json['source'] = nativeToJson<String>(source);
    json['senderType'] = nativeToJson<String>(senderType);
    json['messageSanitized'] = nativeToJson<String>(messageSanitized);
    json['messageLength'] = nativeToJson<int>(messageLength);
    json['hasUrl'] = nativeToJson<bool>(hasUrl);
    json['appVersion'] = nativeToJson<String>(appVersion);
    return json;
  }

  const InsertModelFeedbackVariables({
    required this.label,
    required this.aiPrediction,
    required this.userCorrection,
    required this.source,
    required this.senderType,
    required this.messageSanitized,
    required this.messageLength,
    required this.hasUrl,
    required this.appVersion,
  });
}

