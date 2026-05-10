import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_service.dart';

class FriendRequestNotificationService {
  FriendRequestNotificationService._internal();

  static const MethodChannel _nativeChannel =
      MethodChannel('friend_request_notification_channel');

  static final FriendRequestNotificationService _instance =
      FriendRequestNotificationService._internal();

  factory FriendRequestNotificationService() => _instance;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  final Set<String> _notifiedRequestKeys = <String>{};
  bool _loadedPersistedKeys = false;
  bool _nativeHandlerRegistered = false;

  String get _currentUserId => _auth.currentUser?.uid ?? '';
  String get _prefsKey => 'friend_request_notified_keys_$_currentUserId';

  void Function({
    required String senderId,
    required String senderName,
  })? onFriendRequestNotificationTap;

  void start() {
    final userId = _currentUserId;
    if (userId.isEmpty || _subscription != null) return;

    _subscription = _firestore
        .collection('users')
        .doc(userId)
        .collection('friend_requests')
        .snapshots()
        .listen((snapshot) {
      unawaited(_handleSnapshot(snapshot));
    });
  }

  void setupNativeFriendRequestHandler() {
    if (_nativeHandlerRegistered) return;
    _nativeHandlerRegistered = true;

    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method != 'onFriendRequestIntentReceived') return;
      final args = Map<String, dynamic>.from(call.arguments ?? {});
      await _handleNativeIntent(args);
    });

    unawaited(_consumePendingNativeIntent());
  }

  Future<void> _consumePendingNativeIntent() async {
    try {
      final pendingArgs = await _nativeChannel.invokeMethod<dynamic>(
        'consumePendingFriendRequestIntent',
      );
      if (pendingArgs == null) return;
      await _handleNativeIntent(
        Map<String, dynamic>.from(pendingArgs as Map<dynamic, dynamic>),
      );
    } catch (_) {}
  }

  Future<void> _handleNativeIntent(Map<String, dynamic> args) async {
    final senderId = args['senderId'] as String? ?? '';
    final senderName = args['senderName'] as String? ?? 'Someone';

    if (senderId.isEmpty) return;

    onFriendRequestNotificationTap?.call(
      senderId: senderId,
      senderName: senderName,
    );

    try {
      await _nativeChannel.invokeMethod('markFriendRequestIntentHandled', {
        'senderId': senderId,
      });
    } catch (_) {}
  }

  Future<void> _handleSnapshot(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) async {
    await _ensureLoadedPersistedKeys();

    final changedDocs = snapshot.docChanges
        .where((change) => change.type == DocumentChangeType.added)
        .map((change) => change.doc)
        .toList();

    final docsToCheck = changedDocs.isNotEmpty ? changedDocs : snapshot.docs;

    for (final doc in docsToCheck) {
      final requestKey = _requestKeyForDoc(doc);
      if (_notifiedRequestKeys.contains(requestKey)) continue;

      final data = doc.data();
      final senderId = doc.id;
      final senderName = data?['name']?.toString().trim().isNotEmpty == true
          ? data!['name'].toString().trim()
          : data?['email']?.toString().trim().isNotEmpty == true
              ? data!['email'].toString().trim()
              : 'Someone';

      await NotificationService.showFriendRequestNotification(
        senderId: senderId,
        sender: senderName,
      );
      _notifiedRequestKeys.add(requestKey);
      await _persistNotifiedKeys();
    }
  }

  String _requestKeyForDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? <String, dynamic>{};
    final createdAt = data['createdAt'];
    if (createdAt is Timestamp) {
      return '${doc.id}_${createdAt.millisecondsSinceEpoch}';
    }
    return doc.id;
  }

  Future<void> _ensureLoadedPersistedKeys() async {
    if (_loadedPersistedKeys || _currentUserId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getStringList(_prefsKey) ?? const <String>[];
    _notifiedRequestKeys
      ..clear()
      ..addAll(stored);
    _loadedPersistedKeys = true;
  }

  Future<void> _persistNotifiedKeys() async {
    if (_currentUserId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, _notifiedRequestKeys.toList());
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _notifiedRequestKeys.clear();
    _loadedPersistedKeys = false;
  }
}
