import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserProfileService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Display names are stable within a session; cache them to avoid a Firestore
  // read on every outgoing message send.
  final Map<String, String> _displayNameCache = <String, String>{};
  final Map<String, DateTime> _displayNameCacheTime = <String, DateTime>{};
  static const Duration _displayNameCacheTtl = Duration(minutes: 5);

  static String resolveDisplayName({
    Map<String, dynamic>? data,
    User? authUser,
    String fallback = 'Unknown User',
  }) {
    final firestoreName = data?['name']?.toString().trim() ?? '';
    if (firestoreName.isNotEmpty) return firestoreName;

    final firestoreDisplayName = data?['displayName']?.toString().trim() ?? '';
    if (firestoreDisplayName.isNotEmpty) return firestoreDisplayName;

    final authDisplayName = authUser?.displayName?.trim() ?? '';
    if (authDisplayName.isNotEmpty) return authDisplayName;

    final email = data?['email']?.toString().trim() ?? authUser?.email?.trim() ?? '';
    if (email.isNotEmpty) {
      final localPart = email.split('@').first.trim();
      if (localPart.isNotEmpty) return localPart;
      return email;
    }

    return fallback;
  }

  Future<String> getCurrentUserDisplayName({String fallback = 'Unknown User'}) async {
    final user = _auth.currentUser;
    final uid = user?.uid;
    if (uid == null || uid.isEmpty) {
      return resolveDisplayName(authUser: user, fallback: fallback);
    }

    // Return cached value if still fresh.
    final cached = _displayNameCache[uid];
    final cachedAt = _displayNameCacheTime[uid];
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _displayNameCacheTtl) {
      return cached;
    }

    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      final name = resolveDisplayName(
        data: doc.data(),
        authUser: user,
        fallback: fallback,
      );
      _displayNameCache[uid] = name;
      _displayNameCacheTime[uid] = DateTime.now();
      return name;
    } catch (_) {
      return resolveDisplayName(authUser: user, fallback: fallback);
    }
  }

  Future<String> fetchDisplayName(
    String uid, {
    String fallback = 'Unknown User',
  }) async {
    if (uid.trim().isEmpty) return fallback;

    // Return cached value if still fresh.
    final cached = _displayNameCache[uid];
    final cachedAt = _displayNameCacheTime[uid];
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _displayNameCacheTtl) {
      return cached;
    }

    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      final name = resolveDisplayName(
        data: doc.data(),
        fallback: fallback,
      );
      _displayNameCache[uid] = name;
      _displayNameCacheTime[uid] = DateTime.now();
      return name;
    } catch (_) {
      return fallback;
    }
  }

  Future<void> propagateDisplayNameChange({
    required String userId,
    required String displayName,
  }) async {
    final cleanUserId = userId.trim();
    final cleanDisplayName = displayName.trim();
    if (cleanUserId.isEmpty || cleanDisplayName.isEmpty) return;

    await _updateCollectionGroupNames(
      collectionName: 'contacts',
      userId: cleanUserId,
      displayName: cleanDisplayName,
    );
    await _updateCollectionGroupNames(
      collectionName: 'friend_requests',
      userId: cleanUserId,
      displayName: cleanDisplayName,
    );
    await _updateCollectionGroupNames(
      collectionName: 'sent_friend_requests',
      userId: cleanUserId,
      displayName: cleanDisplayName,
    );
    await _updateChatParticipantNames(
      userId: cleanUserId,
      displayName: cleanDisplayName,
    );
  }

  Future<void> _updateCollectionGroupNames({
    required String collectionName,
    required String userId,
    required String displayName,
  }) async {
    final snapshot = await _firestore
        .collectionGroup(collectionName)
        .where('uid', isEqualTo: userId)
        .get();

    if (snapshot.docs.isEmpty) return;

    WriteBatch batch = _firestore.batch();
    var pending = 0;

    for (final doc in snapshot.docs) {
      batch.set(doc.reference, {
        'name': displayName,
      }, SetOptions(merge: true));
      pending++;

      if (pending >= 400) {
        await batch.commit();
        batch = _firestore.batch();
        pending = 0;
      }
    }

    if (pending > 0) {
      await batch.commit();
    }
  }

  Future<void> _updateChatParticipantNames({
    required String userId,
    required String displayName,
  }) async {
    final snapshot = await _firestore
        .collection('chats')
        .where('participants', arrayContains: userId)
        .get();

    if (snapshot.docs.isEmpty) return;

    WriteBatch batch = _firestore.batch();
    var pending = 0;

    for (final doc in snapshot.docs) {
      batch.set(doc.reference, {
        'participantNames': {
          userId: displayName,
        },
      }, SetOptions(merge: true));
      pending++;

      if (pending >= 400) {
        await batch.commit();
        batch = _firestore.batch();
        pending = 0;
      }
    }

    if (pending > 0) {
      await batch.commit();
    }
  }
}
