// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkeep/flutter_callkeep.dart';

import 'native_channel_router.dart';

class CallNotificationService {
  static final CallNotificationService _instance =
      CallNotificationService._internal();

  factory CallNotificationService() => _instance;

  CallNotificationService._internal();

  static StreamSubscription<QuerySnapshot>? _callSubscription;
  static StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _activeCallDocSubscription;
  static final Set<String> _handledCallIds = <String>{};
  static bool _isListening = false;
  static bool _nativeHandlerRegistered = false;
  static String? _activeCallId;
  static int? _nativeIntentHandlerId;
  static final ValueNotifier<Map<String, dynamic>?> activeCallState =
      ValueNotifier<Map<String, dynamic>?>(null);

  static const MethodChannel _channel = NativeChannelRouter.channel;

  void Function({
    required String action,
    required String callId,
    required String callerName,
    required bool isVideo,
  })? onIncomingCallFromBackground;

  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  static Future<void> configure() async {
    final config = CallKeepConfig(
      appName: 'Smishing Shield PH',
      acceptText: 'Accept',
      declineText: 'Decline',
      missedCallText: 'Missed call',
      callBackText: 'Call back',
      android: CallKeepAndroidConfig(
        logo: 'ic_launcher',
        showCallBackAction: true,
        showMissedCallNotification: true,
        ringtoneFileName: 'system_ringtone_default',
        accentColor: '#075E54',
        backgroundUrl: '',
        incomingCallNotificationChannelName: 'Incoming Calls',
        missedCallNotificationChannelName: 'Missed Calls',
      ),
      ios: CallKeepIosConfig(),
    );

    CallKeep.instance.configure(config);
    print('[CallNotif] CallKeep configured');
  }

  static void setActiveCall(String callId) {
    _activeCallId = callId;
    _handledCallIds.add(callId);
    print('[CallNotif] Active call set: $callId');
  }

  static void setActiveCallDetails({
    required String callId,
    required String receiverId,
    required String contactName,
    required bool isVideo,
    required bool isCaller,
    bool isMinimized = false,
  }) {
    setActiveCall(callId);
    final existing = activeCallState.value;
    activeCallState.value = <String, dynamic>{
      'callId': callId,
      'receiverId': receiverId,
      'contactName': contactName,
      'isVideo': isVideo,
      'isCaller': isCaller,
      'isMinimized': isMinimized,
      if (existing != null &&
          existing['callId']?.toString() == callId &&
          existing['connectedAtMillis'] != null)
        'connectedAtMillis': existing['connectedAtMillis'],
    };
    _listenToActiveCall(callId);
  }

  static void setCallMinimized(bool minimized) {
    final current = activeCallState.value;
    if (current == null) return;
    activeCallState.value = <String, dynamic>{
      ...current,
      'isMinimized': minimized,
    };
  }

  static void _listenToActiveCall(String callId) {
    _activeCallDocSubscription?.cancel();
    _activeCallDocSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(callId)
        .snapshots()
        .listen((doc) {
      final current = activeCallState.value;
      if (current == null || current['callId']?.toString() != callId) {
        return;
      }

      if (!doc.exists) {
        clearActiveCall();
        return;
      }

      final data = doc.data() ?? <String, dynamic>{};
      final status = data['status']?.toString() ?? '';
      if (status == 'connected' && current['connectedAtMillis'] == null) {
        activeCallState.value = <String, dynamic>{
          ...current,
          'connectedAtMillis': DateTime.now().millisecondsSinceEpoch,
        };
        return;
      }

      if (status == 'ended' ||
          status == 'declined' ||
          status == 'missed' ||
          status == 'cancelled') {
        clearActiveCall();
      }
    });
  }

  static void clearActiveCall() {
    print('[CallNotif] Active call cleared (was: $_activeCallId)');
    _activeCallDocSubscription?.cancel();
    _activeCallDocSubscription = null;
    if (_activeCallId != null) {
      _handledCallIds.remove(_activeCallId);
    }
    _activeCallId = null;
    activeCallState.value = null;
  }

  static bool isHandled(String callId) {
    return _handledCallIds.contains(callId);
  }

  static void markHandled(String callId) {
    _handledCallIds.add(callId);
  }

  static void unmarkHandled(String callId) {
    _handledCallIds.remove(callId);
    if (_activeCallId == callId) {
      _activeCallId = null;
    }
  }

  Future<void> _markNativeIntentHandled({
    required String action,
    required String callId,
  }) async {
    try {
      await _channel.invokeMethod('markCallIntentHandled', <String, dynamic>{
        'action': action,
        'callId': callId,
      });
    } catch (e) {
      print('[CallNotif] Failed to acknowledge native intent: $e');
    }
  }

  Future<void> _handleNativeIntent(Map<String, dynamic> args) async {
    final callId = args['callId'] as String? ?? '';
    final callerName = args['callerName'] as String? ?? 'Unknown';
    final isVideo = args['isVideo'] as bool? ?? false;
    final action = args['action'] as String? ?? '';

    print('[CallNotif] Native intent received - id=$callId action=$action');

    if (callId.isEmpty) {
      print('[CallNotif] Missing callId, ignoring');
      return;
    }

    if (_activeCallId == callId &&
        action ==
            'com.example.flutter_application_1.ACTION_OPEN_FROM_NOTIFICATION') {
      print('[CallNotif] Notification tap ignored, already active: $callId');
      await _markNativeIntentHandled(action: action, callId: callId);
      return;
    }

    if (action == 'com.example.flutter_application_1.ACTION_ACCEPT_CALL' ||
        action ==
            'com.example.flutter_application_1.ACTION_OPEN_FROM_NOTIFICATION') {
      _activeCallId = callId;
      _handledCallIds.add(callId);

      onIncomingCallFromBackground?.call(
        action: action,
        callId: callId,
        callerName: callerName,
        isVideo: isVideo,
      );

      await _markNativeIntentHandled(action: action, callId: callId);
      return;
    }

    print('[CallNotif] Unhandled native action: $action');
    await _markNativeIntentHandled(action: action, callId: callId);
  }

  void setupNativeCallHandler() {
    if (_nativeHandlerRegistered) {
      print('[CallNotif] Native handler already registered - skipping');
      return;
    }

    _nativeHandlerRegistered = true;

    _nativeIntentHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'onCallIntentReceived',
      handler: (call) async {
        final args = Map<String, dynamic>.from(call.arguments ?? {});
        await _handleNativeIntent(args);
      },
    );

    print('[CallNotif] Native call handler registered');
    unawaited(_consumePendingNativeIntent());
  }

  Future<void> _consumePendingNativeIntent() async {
    try {
      final pendingArgs = await _channel.invokeMethod<dynamic>(
        'consumePendingCallIntent',
      );

      if (pendingArgs == null) {
        print('[CallNotif] No pending native intent to consume');
        return;
      }

      await _handleNativeIntent(
        Map<String, dynamic>.from(pendingArgs as Map<dynamic, dynamic>),
      );
    } catch (e) {
      print('[CallNotif] Failed to consume pending native intent: $e');
    }
  }

  void setEventHandler({
    required void Function(CallEvent event) onAccepted,
    required void Function(CallEvent event) onDeclined,
    required void Function(CallEvent event) onEnded,
    required void Function(CallEvent event) onIncoming,
  }) {
    CallKeep.instance.handler = CallEventHandler(
      onCallIncoming: (event) {
        print('[CallNotif] CallKeep incoming: ${event.callerName}');
        onIncoming(event);
      },
      onCallAccepted: (event) {
        print('[CallNotif] CallKeep accepted: ${event.uuid}');
        _activeCallId = event.uuid;
        _handledCallIds.add(event.uuid);
        onAccepted(event);
      },
      onCallDeclined: (event) async {
        print('[CallNotif] CallKeep declined: ${event.uuid}');
        await FirebaseFirestore.instance
            .collection('calls')
            .doc(event.uuid)
            .set({'status': 'declined'}, SetOptions(merge: true));
        _handledCallIds.remove(event.uuid);
        if (_activeCallId == event.uuid) {
          _activeCallId = null;
        }
        onDeclined(event);
      },
      onCallEnded: (event) {
        print('[CallNotif] CallKeep ended: ${event.uuid}');
        _activeCallId = null;
        _handledCallIds.remove(event.uuid);
        onEnded(event);
      },
      onCallStarted: (event) {
        print('[CallNotif] CallKeep started: ${event.uuid}');
      },
    );
  }

  void startListening() {
    if (currentUserId.isEmpty) {
      print('[CallNotif] No user - skipping startListening');
      return;
    }

    if (_isListening) {
      print('[CallNotif] Already listening - skipping');
      return;
    }

    _isListening = true;
    print('[CallNotif] Starting Firestore listener (userId: $currentUserId)');

    _callSubscription = FirebaseFirestore.instance
        .collection('calls')
        .where('calleeId', isEqualTo: currentUserId)
        .where('status', isEqualTo: 'ringing')
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type != DocumentChangeType.added) continue;

        final callId = change.doc.id;
        final data = change.doc.data()!;
        final callerName = data['callerName'] ?? 'Unknown';
        final isVideo = data['isVideo'] ?? false;

        if (_activeCallId == callId) {
          print('[CallNotif] Firestore: $callId is active call - skipping');
          continue;
        }

        if (_handledCallIds.contains(callId)) {
          print('[CallNotif] Firestore: $callId already handled - skipping');
          continue;
        }

        print('[CallNotif] Foreground call from $callerName (id: $callId)');

        if (Platform.isIOS) {
          _handledCallIds.add(callId);
          _showIncomingCall(
            callId: callId,
            callerName: callerName,
            isVideo: isVideo,
          );
        } else {
          print('[CallNotif] Android Firestore fallback disabled for $callId');
        }
      }
    });
  }

  Future<void> _showIncomingCall({
    required String callId,
    required String callerName,
    required bool isVideo,
  }) async {
    try {
      final callEvent = CallEvent(
        uuid: callId,
        callerName: callerName,
        handle: callerName,
        hasVideo: isVideo,
        duration: 30000,
        extra: <String, dynamic>{'callId': callId},
      );

      await CallKeep.instance.displayIncomingCall(callEvent);
      print('[CallNotif] Displaying CallKeep UI for $callerName');
    } catch (e) {
      print('[CallNotif] Error displaying call: $e');
    }
  }

  Future<void> endCall(String callId) async {
    try {
      if (Platform.isIOS) {
        await CallKeep.instance.endCall(callId);
      }
      _handledCallIds.remove(callId);
      if (_activeCallId == callId) {
        _activeCallId = null;
      }
      print('[CallNotif] Call ended: $callId');
    } catch (e) {
      print('[CallNotif] endCall error: $e');
    }
  }

  Future<void> endAllCalls() async {
    try {
      if (Platform.isIOS) {
        await CallKeep.instance.endAllCalls();
      }
      _handledCallIds.clear();
      _activeCallId = null;
      print('[CallNotif] All calls ended');
    } catch (e) {
      print('[CallNotif] endAllCalls error: $e');
    }
  }

  void stopListening() {
    _callSubscription?.cancel();
    _callSubscription = null;
    _handledCallIds.clear();
    _isListening = false;
    _activeCallId = null;
    print('[CallNotif] Stopped listening');
  }
}
