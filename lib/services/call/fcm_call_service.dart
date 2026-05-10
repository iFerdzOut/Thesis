// ignore_for_file: avoid_print

import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;

class FcmCallService {
  static final FcmCallService _instance = FcmCallService._internal();
  factory FcmCallService() => _instance;
  FcmCallService._internal();

  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get currentUserName =>
      FirebaseAuth.instance.currentUser?.displayName ??
      FirebaseAuth.instance.currentUser?.email ??
      currentUserId;

  static const String _callPushEndpoint =
      'https://smishing-call-push-backend.vercel.app/api/send-call-push';

  Future<void> init() async {
    try {
      await _fcm.requestPermission(
        alert: true,
        sound: true,
        badge: true,
      );

      final token = await _fcm.getToken();
      if (token != null && token.isNotEmpty) {
        await _saveToken(token);
        print('[FcmCallService] Token saved');
      }

      _fcm.onTokenRefresh.listen((token) async {
        await _saveToken(token);
        print('[FcmCallService] Token refreshed');
      });
    } catch (e) {
      print('[FcmCallService] init error: $e');
    }
  }

  Future<void> _saveToken(String token) async {
    if (currentUserId.isEmpty) return;

    await _db.collection('users').doc(currentUserId).set({
      'fcmToken': token,
    }, SetOptions(merge: true));
  }

  Future<void> notifyIncomingCall({
    required String calleeId,
    required String callId,
    required String callerName,
    required bool isVideo,
  }) async {
    try {
      final calleeDoc = await _db.collection('users').doc(calleeId).get();
      final fcmToken = calleeDoc.data()?['fcmToken'] as String?;

      if (fcmToken == null || fcmToken.isEmpty) {
        print('[FcmCallService] No FCM token for callee=$calleeId');
        return;
      }

      await _db.collection('calls').doc(callId).set({
        'calleeFcmToken': fcmToken,
      }, SetOptions(merge: true));

      final payload = {
        'token': fcmToken,
        'type': 'call',
        'callId': callId,
        'callerId': currentUserId,
        'callerName': callerName,
        'calleeId': calleeId,
        'isVideo': isVideo,
      };

      print('[FcmCallService] Sending push payload: $payload');

      final response = await http.post(
        Uri.parse(_callPushEndpoint),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      );

      print(
        '[FcmCallService] Push response: ${response.statusCode} ${response.body}',
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        print('[FcmCallService] Push request sent successfully');
      } else if (response.statusCode == 500 &&
          response.body.contains('Requested entity was not found')) {
        print('[FcmCallService] Stale token detected, clearing saved token');
        await _db.collection('users').doc(calleeId).update({
          'fcmToken': FieldValue.delete(),
        });
      } else {
        print('[FcmCallService] Push request failed');
      }
    } catch (e) {
      print('[FcmCallService] notifyIncomingCall error: $e');
    }
  }

  Future<String?> getToken() => _fcm.getToken();
}