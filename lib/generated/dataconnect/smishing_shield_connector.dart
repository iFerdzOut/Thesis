library smishing_shield_dataconnect;
import 'package:firebase_data_connect/firebase_data_connect.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';

part 'list_model_feedbacks.dart';
part 'insert_model_feedback.dart';







class SmishingShieldConnectorConnector {
  
  
  InsertModelFeedbackVariablesBuilder insertModelFeedback ({required String label, required String aiPrediction, required String userCorrection, required String source, required String senderType, required String messageSanitized, required int messageLength, required bool hasUrl, required String appVersion, }) {
    return InsertModelFeedbackVariablesBuilder(dataConnect, label: label, aiPrediction: aiPrediction, userCorrection: userCorrection, source: source, senderType: senderType, messageSanitized: messageSanitized, messageLength: messageLength, hasUrl: hasUrl, appVersion: appVersion,);
  }
  
  ListModelFeedbacksVariablesBuilder listModelFeedbacks () {
    return ListModelFeedbacksVariablesBuilder(dataConnect, );
  }
  

  static ConnectorConfig connectorConfig = ConnectorConfig(
    'asia-southeast1',
    'smishing-shield-connector',
    'shimishing-shield-ph-service',
  );

  SmishingShieldConnectorConnector({required this.dataConnect});
  static SmishingShieldConnectorConnector get instance {
    
    return SmishingShieldConnectorConnector(
        dataConnect: FirebaseDataConnect.instanceFor(
            connectorConfig: connectorConfig,
            
            sdkType: CallerSDKType.generated));
  }

  FirebaseDataConnect dataConnect;
}
