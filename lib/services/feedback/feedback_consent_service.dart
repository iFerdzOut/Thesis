import 'package:shared_preferences/shared_preferences.dart';

class FeedbackConsentService {
  FeedbackConsentService._();

  static const String _uploadConsentKey = 'model_feedback_upload_consent_v1';
  static const String _promptSeenKey = 'model_feedback_prompt_seen_v1';

  static Future<bool> isUploadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_uploadConsentKey) ?? false;
  }

  static Future<void> setUploadEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_uploadConsentKey, enabled);
    await prefs.setBool(_promptSeenKey, true);
  }

  static Future<bool> hasAnsweredConsentPrompt() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_promptSeenKey) ?? false;
  }
}
