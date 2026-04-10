import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'contacts_service.dart';

class DeviceContactSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final ContactsServiceHelper _contactsService = ContactsServiceHelper();

  String get currentUserId => _auth.currentUser?.uid ?? '';

  static String normalizePhone(String raw) {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '';

    if (digits.length >= 10) {
      return digits.substring(digits.length - 10);
    }

    return digits;
  }

  Future<void> syncDeviceContacts() async {
    if (currentUserId.isEmpty) return;

    final contacts = await _contactsService.getContacts();
    final usersSnapshot = await _firestore.collection('users').get();

    final usersByPhone = <String, Map<String, dynamic>>{};
    for (final doc in usersSnapshot.docs) {
      final data = doc.data();
      final keys = <String>[
        data['phoneMatchKey']?.toString() ?? '',
        normalizePhone(data['phone']?.toString() ?? ''),
        normalizePhone(data['phoneNumber']?.toString() ?? ''),
        normalizePhone(data['mobile']?.toString() ?? ''),
      ].where((value) => value.isNotEmpty);

      for (final key in keys) {
        usersByPhone[key] = data;
      }
    }

    final batch = _firestore.batch();
    final seenDocIds = <String>{};

    for (final contact in contacts) {
      final phones = contact.phones
          .map((phone) => phone.number.trim())
          .where((phone) => phone.isNotEmpty)
          .toList();

      if (phones.isEmpty) continue;

      final primaryPhone = phones.first;
      final matchKey = normalizePhone(primaryPhone);
      if (matchKey.isEmpty) continue;

      final docId =
          '${contact.id}_$matchKey'.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      seenDocIds.add(docId);

      final matchedUser = usersByPhone[matchKey];
      final matchedUserId = matchedUser?['uid']?.toString() ?? '';

      final ref = _firestore
          .collection('users')
          .doc(currentUserId)
          .collection('device_contacts')
          .doc(docId);

      batch.set(
          ref,
          {
            'contactId': contact.id,
            'displayName': contact.displayName,
            'primaryPhone': primaryPhone,
            'phoneMatchKey': matchKey,
            'allPhones': phones,
            'isRegistered':
                matchedUserId.isNotEmpty && matchedUserId != currentUserId,
            'matchedUserId': matchedUserId,
            'matchedName': matchedUser?['name']?.toString() ?? '',
            'matchedEmail': matchedUser?['email']?.toString() ?? '',
            'syncedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true));
    }

    await batch.commit();
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> getSyncedContacts() {
    return _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('device_contacts')
        .orderBy('displayName')
        .snapshots();
  }

  Future<List<Map<String, dynamic>>> getSyncedContactsOnce() async {
    if (currentUserId.isEmpty) return <Map<String, dynamic>>[];

    final snapshot = await _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('device_contacts')
        .orderBy('displayName')
        .get();

    return snapshot.docs.map((doc) {
      final data = doc.data();
      return <String, dynamic>{
        'docId': doc.id,
        ...data,
      };
    }).toList();
  }

  Future<void> markInviteSent(String docId) async {
    if (currentUserId.isEmpty || docId.isEmpty) return;

    await _firestore
        .collection('users')
        .doc(currentUserId)
        .collection('device_contacts')
        .doc(docId)
        .set({
      'lastInvitedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
