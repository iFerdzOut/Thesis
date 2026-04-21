part of 'smishing_shield_connector.dart';

class ListModelFeedbacksVariablesBuilder {
  
  final FirebaseDataConnect _dataConnect;
  ListModelFeedbacksVariablesBuilder(this._dataConnect, );
  Deserializer<ListModelFeedbacksData> dataDeserializer = (dynamic json)  => ListModelFeedbacksData.fromJson(jsonDecode(json));
  
  Future<QueryResult<ListModelFeedbacksData, void>> execute() {
    return ref().execute();
  }

  QueryRef<ListModelFeedbacksData, void> ref() {
    
    return _dataConnect.query("ListModelFeedbacks", dataDeserializer, emptySerializer, null);
  }
}

@immutable
class ListModelFeedbacksModelFeedbacks {
  final String id;
  final String label;
  final String source;
  final Timestamp reportedAt;
  ListModelFeedbacksModelFeedbacks.fromJson(dynamic json):
  
  id = nativeFromJson<String>(json['id']),
  label = nativeFromJson<String>(json['label']),
  source = nativeFromJson<String>(json['source']),
  reportedAt = Timestamp.fromJson(json['reportedAt']);
  @override
  bool operator ==(Object other) {
    if(identical(this, other)) {
      return true;
    }
    if(other.runtimeType != runtimeType) {
      return false;
    }

    final ListModelFeedbacksModelFeedbacks otherTyped = other as ListModelFeedbacksModelFeedbacks;
    return id == otherTyped.id && 
    label == otherTyped.label && 
    source == otherTyped.source && 
    reportedAt == otherTyped.reportedAt;
    
  }
  @override
  int get hashCode => Object.hashAll([id.hashCode, label.hashCode, source.hashCode, reportedAt.hashCode]);
  

  Map<String, dynamic> toJson() {
    Map<String, dynamic> json = {};
    json['id'] = nativeToJson<String>(id);
    json['label'] = nativeToJson<String>(label);
    json['source'] = nativeToJson<String>(source);
    json['reportedAt'] = reportedAt.toJson();
    return json;
  }

  const ListModelFeedbacksModelFeedbacks({
    required this.id,
    required this.label,
    required this.source,
    required this.reportedAt,
  });
}

@immutable
class ListModelFeedbacksData {
  final List<ListModelFeedbacksModelFeedbacks> modelFeedbacks;
  ListModelFeedbacksData.fromJson(dynamic json):
  
  modelFeedbacks = (json['modelFeedbacks'] as List<dynamic>)
        .map((e) => ListModelFeedbacksModelFeedbacks.fromJson(e))
        .toList();
  @override
  bool operator ==(Object other) {
    if(identical(this, other)) {
      return true;
    }
    if(other.runtimeType != runtimeType) {
      return false;
    }

    final ListModelFeedbacksData otherTyped = other as ListModelFeedbacksData;
    return modelFeedbacks == otherTyped.modelFeedbacks;
    
  }
  @override
  int get hashCode => modelFeedbacks.hashCode;
  

  Map<String, dynamic> toJson() {
    Map<String, dynamic> json = {};
    json['modelFeedbacks'] = modelFeedbacks.map((e) => e.toJson()).toList();
    return json;
  }

  const ListModelFeedbacksData({
    required this.modelFeedbacks,
  });
}

