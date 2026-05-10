import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionIdentityService {
  SessionIdentityService._internal();

  static final SessionIdentityService instance =
      SessionIdentityService._internal();

  static const String _guestIdKey = 'sms_guest_storage_id_v1';
  String? _guestStorageId;

  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_guestIdKey)?.trim() ?? '';
    if (existing.isNotEmpty) {
      _guestStorageId = existing;
      return;
    }

    final generated = 'guest_${DateTime.now().millisecondsSinceEpoch}';
    await prefs.setString(_guestIdKey, generated);
    _guestStorageId = generated;
  }

  String get smsStorageUserId {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && !user.isAnonymous) {
      return user.uid;
    }
    return _guestStorageId ?? 'guest_local';
  }

  bool get hasAuthenticatedUser {
    final user = FirebaseAuth.instance.currentUser;
    return user != null && !user.isAnonymous;
  }
}
