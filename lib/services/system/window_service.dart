import 'package:flutter/services.dart';

class WindowService {
  static const MethodChannel _channel = MethodChannel('sms_channel');

  /// Call this on QuarantineScreen to block screenshots and screen recording
  static Future<void> enableSecureScreen() async {
    try {
      await _channel.invokeMethod('setSecureScreen', {'enable': true});
    } catch (e) {
      // ignore if called before engine is ready
    }
  }

  /// Call this when leaving QuarantineScreen to re-enable screenshots
  static Future<void> disableSecureScreen() async {
    try {
      await _channel.invokeMethod('setSecureScreen', {'enable': false});
    } catch (e) {
      // ignore if called before engine is ready
    }
  }
}