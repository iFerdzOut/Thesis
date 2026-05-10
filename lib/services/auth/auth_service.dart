import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  static const String _lastAuthenticatedUidKey = 'last_authenticated_uid_v1';
  final FirebaseAuth _auth = FirebaseAuth.instance;

  static Future<void> persistSessionMarker([User? user]) async {
    final resolvedUser = user ?? FirebaseAuth.instance.currentUser;
    if (resolvedUser == null || resolvedUser.isAnonymous) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastAuthenticatedUidKey, resolvedUser.uid);
  }

  static Future<bool> hasPersistedSessionMarker() async {
    final prefs = await SharedPreferences.getInstance();
    final storedUid = prefs.getString(_lastAuthenticatedUidKey)?.trim() ?? '';
    return storedUid.isNotEmpty;
  }

  static Future<void> clearPersistedSessionMarker() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastAuthenticatedUidKey);
  }

  Future<UserCredential> register({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await persistSessionMarker(credential.user);
    return credential;
  }

  Future<UserCredential> login({
    required String email,
    required String password,
  }) async {
    final credential = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    await persistSessionMarker(credential.user);
    return credential;
  }

  Future<void> sendPasswordResetEmail({required String email}) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  Future<void> logout() async {
    await clearPersistedSessionMarker();
    await _auth.signOut();
  }

  User? get currentUser => _auth.currentUser;
}
