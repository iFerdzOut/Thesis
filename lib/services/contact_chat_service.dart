import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'user_profile_service.dart';

class ContactChatService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  String get currentUserId => _auth.currentUser!.uid;

  Future<Map<String, String>> _getCurrentUserProfile() async {
    final userDoc =
        await _firestore.collection('users').doc(currentUserId).get();
    final data = userDoc.data() ?? <String, dynamic>{};
    final resolvedName = UserProfileService.resolveDisplayName(
      data: data,
      authUser: _auth.currentUser,
      fallback: 'Unknown User',
    );

    return {
      'name': resolvedName,
      'email': (data['email'] as String?)?.trim().isNotEmpty == true
          ? (data['email'] as String).trim()
          : (_auth.currentUser?.email ?? ''),
    };
  }

  Future<void> addContact({
    required String contactUid,
    required String name,
    required String email,
  }) async {
    await _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('contacts')
        .doc(contactUid)
        .set({
      'uid': contactUid,
      'name': name,
      'email': email,
      'addedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> sendFriendRequest({
    required String targetUid,
    required String targetName,
    required String targetEmail,
  }) async {
    if (targetUid.isEmpty || targetUid == currentUserId) return;

    final me = await _getCurrentUserProfile();
    final batch = _firestore.batch();

    final incomingRef = _firestore
        .collection('users')
        .doc(targetUid)
        .collection('friend_requests')
        .doc(currentUserId);

    final sentRef = _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('sent_friend_requests')
        .doc(targetUid);

    batch.set(incomingRef, {
      'uid': currentUserId,
      'name': me['name'],
      'displayName': me['name'],
      'email': me['email'],
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });

    batch.set(sentRef, {
      'uid': targetUid,
      'name': targetName,
      'displayName': targetName,
      'email': targetEmail,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
    });

    await batch.commit();
  }

  Future<void> acceptFriendRequest({
    required String requesterUid,
    required String requesterName,
    required String requesterEmail,
  }) async {
    if (requesterUid.isEmpty || requesterUid == currentUserId) return;

    final me = await _getCurrentUserProfile();
    final batch = _firestore.batch();

    final myContactRef = _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('contacts')
        .doc(requesterUid);
    final theirContactRef = _firestore
        .collection('users')
        .doc(requesterUid)
        .collection('contacts')
        .doc(currentUserId);

    final incomingRef = _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('friend_requests')
        .doc(requesterUid);
    final sentRef = _firestore
        .collection('users')
        .doc(requesterUid)
        .collection('sent_friend_requests')
        .doc(currentUserId);

    batch.set(myContactRef, {
      'uid': requesterUid,
      'name': requesterName,
      'displayName': requesterName,
      'email': requesterEmail,
      'addedAt': FieldValue.serverTimestamp(),
    });

    batch.set(theirContactRef, {
      'uid': currentUserId,
      'name': me['name'],
      'displayName': me['name'],
      'email': me['email'],
      'addedAt': FieldValue.serverTimestamp(),
    });

    batch.delete(incomingRef);
    batch.delete(sentRef);

    await batch.commit();
  }

  Future<void> declineFriendRequest({
    required String requesterUid,
  }) async {
    if (requesterUid.isEmpty) return;

    final batch = _firestore.batch();

    batch.delete(
      _firestore
          .collection('users')
          .doc(currentUserId)
          .collection('friend_requests')
          .doc(requesterUid),
    );

    batch.delete(
      _firestore
          .collection('users')
          .doc(requesterUid)
          .collection('sent_friend_requests')
          .doc(currentUserId),
    );

    await batch.commit();
  }

  Future<void> unfriend(String otherUid) async {
    if (otherUid.isEmpty || otherUid == currentUserId) return;

    final batch = _firestore.batch();
    batch.delete(
      _firestore
          .collection('users')
          .doc(currentUserId)
          .collection('contacts')
          .doc(otherUid),
    );
    batch.delete(
      _firestore
          .collection('users')
          .doc(otherUid)
          .collection('contacts')
          .doc(currentUserId),
    );
    await batch.commit();
  }

  Stream<QuerySnapshot> getMyContacts() {
    return _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('contacts')
        .orderBy('addedAt', descending: false)
        .snapshots();
  }

  Stream<QuerySnapshot> searchAllUsers() {
    return _firestore.collection('users').snapshots();
  }

  Stream<QuerySnapshot> getIncomingFriendRequests() {
    return _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('friend_requests')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }

  Stream<QuerySnapshot> getSentFriendRequests() {
    return _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('sent_friend_requests')
        .orderBy('createdAt', descending: true)
        .snapshots();
  }
}
