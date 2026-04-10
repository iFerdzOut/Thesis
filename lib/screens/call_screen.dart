import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_notification_service.dart';
import '../services/fcm_call_service.dart';
import '../services/native_channel_router.dart';
import '../services/online_chat_service.dart';
import '../services/webrtc_call_service.dart';
import 'chat_screen.dart';

class CallScreen extends StatefulWidget {
  final String contactName;
  final String receiverId;
  final bool isVideo;
  final bool isCaller;
  final String? incomingCallId;
  final bool autoAnswer;
  final bool resumeActiveCall;

  const CallScreen({
    super.key,
    required this.contactName,
    required this.receiverId,
    required this.isVideo,
    required this.isCaller,
    this.incomingCallId,
    this.autoAnswer = false,
    this.resumeActiveCall = false,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final WebRtcCallService callService = WebRtcCallService();
  final OnlineChatService _onlineChatService = OnlineChatService();

  static final Set<String> _outgoingCallLocks = <String>{};

  String? callId;
  bool isLoading = true;
  bool callAnswered = false;
  bool isMuted = false;
  bool isCameraOff = false;
  bool isFrontCamera = true;
  bool isVideoEnabled = false;
  bool isRemoteMuted = false;
  bool isRemoteCameraOff = false;
  String statusText = 'Connecting...';

  String _audioOutput = 'speaker';

  bool _callEnded = false;
  String _endedBy = '';
  bool _hasAutoAnswered = false;
  bool _isStartingOutgoingCall = false;
  bool _hasStartedOutgoingCall = false;
  bool _isAcceptingCall = false;
  bool _isDisposed = false;
  bool _offerWaitStarted = false;
  bool _hasSavedCallSummary = false;
  bool _isInPictureInPictureMode = false;

  bool _shouldDisposeWebRtcOnDispose = false;
  bool _shouldClearActiveCallOnDispose = false;
  bool _shouldResetAudioOnDispose = true;

  Timer? _callTimer;
  Timer? _ringTimer;
  Timer? _reconnectTimeoutTimer;
  int _callSeconds = 0;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _callDocSubscription;
  StreamSubscription<String>? _runtimeStatusSubscription;
  StreamSubscription<int>? _mediaStateSubscription;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  int? _pipHandlerId;

  static const MethodChannel _channel = MethodChannel('sms_channel');

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  String get _outgoingLockKey => '${widget.receiverId}_${widget.isVideo}';

  @override
  void initState() {
    super.initState();

    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    isVideoEnabled = widget.isVideo;
    _runtimeStatusSubscription = callService.runtimeStatuses.listen(
      _handleRuntimeStatus,
    );
    _mediaStateSubscription = callService.mediaStateChanges.listen(
      _handleMediaStateChange,
    );
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen(_handleConnectivityChange);
    _pipHandlerId = NativeChannelRouter.registerHandler(
      method: 'onPictureInPictureModeChanged',
      handler: _handlePictureInPictureModeChanged,
    );
    unawaited(_syncPictureInPictureState());

    if (widget.resumeActiveCall) {
      isLoading = false;
      callAnswered = true;
      callId = widget.incomingCallId;
      statusText = 'Connected';
      final activeCall = CallNotificationService.activeCallState.value;
      final connectedAtMillis =
          (activeCall?['connectedAtMillis'] as num?)?.toInt();
      if (connectedAtMillis != null) {
        final elapsedSeconds =
            ((DateTime.now().millisecondsSinceEpoch - connectedAtMillis) ~/
                    1000)
                .clamp(0, 86400);
        _callSeconds = elapsedSeconds;
      }

      if (callId != null) {
        CallNotificationService.setActiveCallDetails(
          callId: callId!,
          receiverId: widget.receiverId,
          contactName: _displayName,
          isVideo: widget.isVideo,
          isCaller: widget.isCaller,
          isMinimized: false,
        );
        _listenToCallDoc(callId!);
        _startCallTimer();
        unawaited(_syncNativePictureInPictureEligibility());
      }
    } else if (widget.isCaller) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_isDisposed) {
          _startOutgoingCall();
        }
      });
    } else {
      isLoading = false;
      callId = widget.incomingCallId;
      statusText = widget.autoAnswer
          ? 'Connecting...'
          : 'Incoming ${widget.isVideo ? "video" : "voice"} call';

      if (widget.incomingCallId != null) {
        CallNotificationService.setActiveCallDetails(
          callId: widget.incomingCallId!,
          receiverId: widget.receiverId,
          contactName: _displayName,
          isVideo: widget.isVideo,
          isCaller: false,
          isMinimized: false,
        );
        _listenToCallDoc(widget.incomingCallId!);
      }

      if (widget.autoAnswer) {
        _hasAutoAnswered = true;
      } else {
        unawaited(_startRinging());
      }
    }

    unawaited(_syncNativePictureInPictureEligibility());
  }

  @override
  void dispose() {
    _isDisposed = true;
    _releaseOutgoingLock();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_setNativePictureInPictureEnabled(false));

    _callTimer?.cancel();
    _ringTimer?.cancel();
    _reconnectTimeoutTimer?.cancel();
    _callDocSubscription?.cancel();
    _runtimeStatusSubscription?.cancel();
    _mediaStateSubscription?.cancel();
    _connectivitySubscription?.cancel();
    NativeChannelRouter.unregisterHandler(_pipHandlerId);
    _pulseController.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    unawaited(_cleanupOnDispose());

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;

    if (state == AppLifecycleState.resumed) {
      unawaited(_syncPictureInPictureState());
      unawaited(_syncNativePictureInPictureEligibility());
    }
  }

  Future<void> _handlePictureInPictureModeChanged(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments ?? const {});
    final inPictureInPicture = args['isInPictureInPicture'] == true;

    if (!mounted || _isDisposed) return;

    setState(() {
      _isInPictureInPictureMode = inPictureInPicture;
    });

    unawaited(_syncNativePictureInPictureEligibility());
  }

  void _handleMediaStateChange(int _) {
    if (!mounted || _isDisposed) return;
    final remoteHasVideo = callService.hasRemoteVideoTrack;
    final nextRemoteCameraOff = remoteHasVideo ? false : isRemoteCameraOff;
    final nextVideoEnabled = remoteHasVideo ? true : isVideoEnabled;
    if (nextRemoteCameraOff == isRemoteCameraOff &&
        nextVideoEnabled == isVideoEnabled) {
      setState(() {});
      return;
    }
    setState(() {
      isRemoteCameraOff = nextRemoteCameraOff;
      isVideoEnabled = nextVideoEnabled;
    });
  }

  Future<void> _syncPictureInPictureState() async {
    try {
      final inPictureInPicture =
          await _channel.invokeMethod<bool>('isInPictureInPictureMode') ??
              false;
      if (!mounted || _isDisposed) return;
      setState(() {
        _isInPictureInPictureMode = inPictureInPicture;
      });
    } catch (_) {}
  }

  Future<void> _cleanupOnDispose() async {
    await _stopRinging();

    if (_shouldDisposeWebRtcOnDispose) {
      await callService.disposeAll();
      _shouldDisposeWebRtcOnDispose = false;
    }

    if (_shouldClearActiveCallOnDispose) {
      CallNotificationService.clearActiveCall();
      _shouldClearActiveCallOnDispose = false;
    }

    if (_shouldResetAudioOnDispose) {
      await _resetPostCallAudio();
      _shouldResetAudioOnDispose = false;
    }
  }

  void _handleRuntimeStatus(String status) {
    if (!mounted || _isDisposed || _callEnded) return;

    if (status == 'reconnecting' && callAnswered) {
      _startReconnectTimeout();
      setState(() {
        isLoading = true;
        statusText = 'Reconnecting...';
      });
      return;
    }

    if (status == 'connected' && callAnswered) {
      _cancelReconnectTimeout();
      setState(() {
        isLoading = false;
        statusText = 'Connected';
      });
      unawaited(_syncNativePictureInPictureEligibility());
      unawaited(
        _setAudioOutput(
          speaker: isVideoEnabled || _audioOutput == 'speaker',
        ),
      );
    }
  }

  Future<void> _handleConnectivityChange(
    List<ConnectivityResult> results,
  ) async {
    if (!mounted || _isDisposed || _callEnded || !callAnswered) return;

    final hasConnection = results.any(
      (result) => result != ConnectivityResult.none,
    );

    if (!hasConnection) {
      _startReconnectTimeout();
      setState(() {
        isLoading = true;
        statusText = 'Reconnecting...';
      });
      return;
    }

    await callService.requestRecovery();
  }

  void _acquireOutgoingLock() {
    _outgoingCallLocks.add(_outgoingLockKey);
  }

  void _releaseOutgoingLock() {
    _outgoingCallLocks.remove(_outgoingLockKey);
  }

  bool _hasOutgoingLock() {
    return _outgoingCallLocks.contains(_outgoingLockKey);
  }

  void _listenToCallDoc(String id) {
    _callDocSubscription?.cancel();

    _callDocSubscription = FirebaseFirestore.instance
        .collection('calls')
        .doc(id)
        .snapshots()
        .listen((doc) async {
      if (!doc.exists || !mounted || _callEnded || _isDisposed) return;

      final data = doc.data();
      if (data == null) return;

      final status = data['status'] as String? ?? '';
      final localPrefix = widget.isCaller ? 'caller' : 'callee';
      final remotePrefix = widget.isCaller ? 'callee' : 'caller';
      final remoteEnabledVideo = data['${remotePrefix}_videoEnabled'] == true ||
          data['isVideo'] == true;
      final remoteMuted = data['${remotePrefix}_micMuted'] == true;
      final remoteCameraIsOff =
          data['${remotePrefix}_cameraOff'] == true &&
          !callService.hasRemoteVideoTrack;
      final localCameraIsOff = data['${localPrefix}_cameraOff'] == true;

      if (mounted) {
        setState(() {
          isRemoteMuted = remoteMuted;
          isRemoteCameraOff = remoteCameraIsOff;
          if (data['${localPrefix}_cameraOff'] != null) {
            isCameraOff = localCameraIsOff;
          }
        });
      }

      if (remoteEnabledVideo && !isVideoEnabled && mounted) {
        setState(() {
          isVideoEnabled = true;
        });
        unawaited(_syncNativePictureInPictureEligibility());
      }

      if (widget.isCaller && status == 'accepted') {
        setState(() {
          isLoading = true;
          statusText = 'Connecting...';
        });
      }

      if (status == 'connected') {
        if (!callAnswered) {
          setState(() {
            callAnswered = true;
            isLoading = false;
            statusText = 'Connected';
          });
          _stopRinging();
          _startCallTimer();
          unawaited(_syncNativePictureInPictureEligibility());
        } else if (mounted) {
          setState(() {
            isLoading = false;
            statusText = 'Connected';
          });
          unawaited(_syncNativePictureInPictureEligibility());
        }
      } else if (status == 'reconnecting') {
        if (callAnswered && mounted) {
          _startReconnectTimeout();
          setState(() {
            isLoading = true;
            statusText = 'Reconnecting...';
          });
        }
      } else if (status == 'ringing') {
        if (widget.isCaller && mounted) {
          setState(() {
            isLoading = false;
            statusText = 'Calling $_displayName...';
          });
        }
      } else if (status == 'busy') {
        if (mounted && !_isDisposed) {
          setState(() {
            _callEnded = true;
            _endedBy = 'busy';
          });
        }
        _releaseOutgoingLock();
      } else if (status == 'ended' ||
          status == 'declined' ||
          status == 'missed' ||
          status == 'cancelled') {
        await _showCallEndedScreen(endedByMe: false);
        _releaseOutgoingLock();
      }

      if (!widget.isCaller &&
          widget.autoAnswer &&
          _hasAutoAnswered &&
          !_offerWaitStarted &&
          !_isAcceptingCall &&
          !callAnswered &&
          (status == 'ringing' || status == 'accepted')) {
        final offer = data['offer'];
        if (offer != null) {
          _offerWaitStarted = true;
          await _acceptCall();
        }
      }
    });
  }

  void _startCallTimer() {
    if (_callTimer != null) return;
    final activeCall = CallNotificationService.activeCallState.value;
    final connectedAtMillis =
        (activeCall?['connectedAtMillis'] as num?)?.toInt();
    if (connectedAtMillis != null) {
      _callSeconds =
          ((DateTime.now().millisecondsSinceEpoch - connectedAtMillis) ~/ 1000)
              .clamp(0, 86400);
    }

    _callTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_isDisposed) {
        setState(() => _callSeconds++);
      }
    });
  }

  void _startReconnectTimeout() {
    _reconnectTimeoutTimer?.cancel();
    _reconnectTimeoutTimer = Timer(const Duration(seconds: 20), () async {
      if (!mounted || _isDisposed || _callEnded) return;
      if (!_isReconnecting) return;
      await _endCall();
    });
  }

  void _cancelReconnectTimeout() {
    _reconnectTimeoutTimer?.cancel();
    _reconnectTimeoutTimer = null;
  }

  String get _callDuration {
    final m = (_callSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (_callSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _maybeSaveCallSummary() async {
    if (_hasSavedCallSummary || callId == null || !_wasCallConnected) return;

    _hasSavedCallSummary = true;

    try {
      await _onlineChatService.sendCallSummary(
        receiverId: widget.receiverId,
        receiverName: _displayName,
        callId: callId!,
        isVideo: isVideoEnabled || widget.isVideo,
        durationSeconds: _callSeconds,
        senderIdOverride:
            widget.isCaller ? callService.currentUserId : widget.receiverId,
        senderNameOverride:
            widget.isCaller ? callService.currentUserName : _displayName,
      );
    } catch (_) {
      _hasSavedCallSummary = false;
    }
  }

  bool get _wasCallConnected => callAnswered || _callSeconds > 0;

  Future<void> _showCallEndedScreen({required bool endedByMe}) async {
    if (_callEnded) return;

    _callTimer?.cancel();
    _cancelReconnectTimeout();
    await _stopRinging();
    _releaseOutgoingLock();
    await _maybeSaveCallSummary();

    await callService.disposeAll();
    await _resetPostCallAudio();
    await Future<void>.delayed(const Duration(milliseconds: 180));
    await _setNativePictureInPictureEnabled(false);
    CallNotificationService.clearActiveCall();

    _shouldDisposeWebRtcOnDispose = false;
    _shouldClearActiveCallOnDispose = false;
    _shouldResetAudioOnDispose = false;

    if (mounted && !_isDisposed) {
      setState(() {
        _callEnded = true;
        _endedBy = endedByMe ? 'me' : 'them';
      });
    }
  }

  Future<void> _startRinging() async {
    _audioOutput = 'speaker';
    try {
      await _channel.invokeMethod('prepareIncomingRingtoneAudio');
    } catch (_) {}
    await _playRingtone();

    _ringTimer?.cancel();
    _ringTimer = Timer(const Duration(seconds: 30), () {
      if (!callAnswered && mounted && !_isDisposed) {
        _declineCall();
      }
    });
  }

  Future<void> _playRingtone() async {
    try {
      await _channel.invokeMethod('startRingtone');
    } catch (_) {}
  }

  Future<void> _stopRinging() async {
    _ringTimer?.cancel();
    try {
      await _channel.invokeMethod('stopRingtone');
    } catch (_) {}
  }

  Future<void> _resetPostCallAudio() async {
    try {
      await _channel.invokeMethod('resetCallAudioState');
    } catch (_) {}

    _audioOutput = 'speaker';
  }

  bool get _canUseNativePictureInPicture =>
      !_isDisposed &&
      !_callEnded &&
      callAnswered &&
      isVideoEnabled &&
      callId != null &&
      callId!.trim().isNotEmpty;

  Future<void> _setNativePictureInPictureEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod(
        'setVideoCallPictureInPictureEnabled',
        {'enabled': enabled},
      );
    } catch (_) {}
  }

  Future<void> _syncNativePictureInPictureEligibility() async {
    await _setNativePictureInPictureEnabled(_canUseNativePictureInPicture);
  }

  Future<void> _enterPictureInPicture() async {
    if (!mounted ||
        _isDisposed ||
        _callEnded ||
        !callAnswered ||
        !isVideoEnabled) {
      return;
    }

    try {
      await _setNativePictureInPictureEnabled(true);
      final supported =
          await _channel.invokeMethod<bool>('supportsPictureInPicture') ??
              false;
      if (!supported) return;

      final entered =
          await _channel.invokeMethod<bool>('enterPictureInPicture') ?? false;
      if (!mounted || _isDisposed || !entered) return;

      setState(() {
        _isInPictureInPictureMode = true;
      });
    } catch (_) {}
  }

  Future<void> _setAudioOutput({required bool speaker}) async {
    _audioOutput = speaker ? 'speaker' : 'earpiece';
    try {
      await Helper.setSpeakerphoneOn(speaker);
    } catch (_) {}
  }

  void _cycleAudioOutput() {
    setState(() {
      if (_audioOutput == 'earpiece') {
        _audioOutput = 'speaker';
        _setAudioOutput(speaker: true);
      } else {
        _audioOutput = 'earpiece';
        _setAudioOutput(speaker: false);
      }
    });
  }

  IconData get _audioIcon =>
      _audioOutput == 'speaker' ? Icons.volume_up : Icons.hearing;

  String get _audioLabel => _audioOutput == 'speaker' ? 'Speaker' : 'Earpiece';
  bool get _isReconnecting => statusText == 'Reconnecting...';
  String get _displayName {
    final raw = widget.contactName.trim();
    if (raw.isEmpty) return 'Unknown';
    if (!raw.contains('@')) return raw;
    final localPart = raw.split('@').first.trim();
    return localPart.isNotEmpty ? localPart : raw;
  }

  Future<void> _prepareCallAudio({required bool speaker}) async {
    _audioOutput = speaker ? 'speaker' : 'earpiece';

    try {
      await _channel.invokeMethod('resetCallAudioState');
      await Future<void>.delayed(const Duration(milliseconds: 120));
    } catch (_) {}

    try {
      await _channel.invokeMethod(
        'prepareCallAudioState',
        {'speaker': speaker},
      );
      await Future<void>.delayed(const Duration(milliseconds: 160));
    } catch (_) {}
  }

  Future<void> _startOutgoingCall() async {
    if (_isDisposed || _callEnded) return;
    if (_isStartingOutgoingCall || _hasStartedOutgoingCall) return;

    if (_hasOutgoingLock()) {
      if (mounted) {
        setState(() {
          isLoading = false;
          statusText = 'Call already starting...';
        });
      }
      return;
    }

    _isStartingOutgoingCall = true;
    _hasStartedOutgoingCall = true;
    _acquireOutgoingLock();

    try {
      await callService.initRenderers();

      if (mounted && !_isDisposed) {
        setState(() {
          isLoading = true;
          callAnswered = false;
          statusText = isVideoEnabled
              ? 'Starting video call...'
              : 'Calling $_displayName...';
        });
      }

      await _prepareCallAudio(speaker: isVideoEnabled);
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final String id = await callService.makeCall(
        callerId: callService.currentUserId,
        calleeId: widget.receiverId,
        isVideo: isVideoEnabled,
      );

      callId = id;

      CallNotificationService.setActiveCallDetails(
        callId: id,
        receiverId: widget.receiverId,
        contactName: _displayName,
        isVideo: isVideoEnabled,
        isCaller: true,
        isMinimized: false,
      );
      _listenToCallDoc(id);

      await FcmCallService().notifyIncomingCall(
        calleeId: widget.receiverId,
        callId: id,
        callerName: callService.currentUserName,
        isVideo: isVideoEnabled,
      );

      await callService.listenForAnswer(id);

      if (mounted && !_isDisposed) {
        setState(() {
          isLoading = false;
          statusText = 'Calling $_displayName...';
        });
      }

      if (isVideoEnabled) {
        if (mounted && !_isDisposed) {
          setState(() => _audioOutput = 'speaker');
        }
        await _setAudioOutput(speaker: true);
      } else {
        if (mounted && !_isDisposed) {
          setState(() => _audioOutput = 'earpiece');
        }
        await _setAudioOutput(speaker: false);
      }
    } catch (e) {
      _releaseOutgoingLock();
      _hasStartedOutgoingCall = false;

      if (mounted && !_isDisposed) {
        setState(() {
          isLoading = false;
          statusText = 'Call failed: $e';
        });
      }
    } finally {
      _isStartingOutgoingCall = false;
    }
  }

  Future<Map<String, dynamic>?> _waitForOffer(String id) async {
    for (int i = 0; i < 10; i++) {
      final snap =
          await FirebaseFirestore.instance.collection('calls').doc(id).get();
      final data = snap.data();
      if (data != null && data['offer'] != null) {
        return data;
      }
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return null;
  }

  Future<void> _acceptCall() async {
    if (callId == null || _isAcceptingCall || _isDisposed || callAnswered) {
      return;
    }

    _isAcceptingCall = true;

    await _stopRinging();

    if (mounted) {
      setState(() {
        isLoading = true;
        statusText = 'Connecting...';
      });
    }

    try {
      final offerData = await _waitForOffer(callId!);
      if (offerData == null) {
        throw Exception('Offer not ready yet');
      }

      await _prepareCallAudio(speaker: isVideoEnabled);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await callService.initRenderers();
      await callService.answerCall(
        callId: callId!,
        isVideo: isVideoEnabled,
      );
      await callService.listenForOfferCandidates(callId!);

      if (mounted && !_isDisposed) {
        setState(() {
          isLoading = false;
          callAnswered = true;
          statusText = 'Connected';
        });
      }

      _startCallTimer();
      await _syncNativePictureInPictureEligibility();

      if (isVideoEnabled) {
        if (mounted && !_isDisposed) {
          setState(() => _audioOutput = 'speaker');
        }
        await _setAudioOutput(speaker: true);
      } else {
        if (mounted && !_isDisposed) {
          setState(() => _audioOutput = 'earpiece');
        }
        await _setAudioOutput(speaker: false);
      }
    } catch (e) {
      if (mounted && !_isDisposed) {
        setState(() {
          isLoading = false;
          statusText = 'Failed to connect: $e';
        });
      }
    } finally {
      _isAcceptingCall = false;
    }
  }

  Future<void> _declineCall() async {
    await _stopRinging();
    _releaseOutgoingLock();
    await _setNativePictureInPictureEnabled(false);

    _shouldDisposeWebRtcOnDispose = true;
    _shouldClearActiveCallOnDispose = true;

    if (callId != null) {
      await FirebaseFirestore.instance.collection('calls').doc(callId!).set({
        'status': 'declined',
      }, SetOptions(merge: true));
      await callService.disposeAll();
    }

    CallNotificationService.clearActiveCall();
    _shouldDisposeWebRtcOnDispose = false;
    _shouldClearActiveCallOnDispose = false;
    await _resetPostCallAudio();
    _shouldResetAudioOnDispose = false;

    if (!mounted || _isDisposed) return;
    Navigator.pop(context);
  }

  Future<void> _endCall() async {
    _releaseOutgoingLock();
    await _setNativePictureInPictureEnabled(false);

    _shouldDisposeWebRtcOnDispose = true;
    _shouldClearActiveCallOnDispose = true;

    if (callId != null) {
      await callService.endCall(callId!);
    }

    await _showCallEndedScreen(endedByMe: true);
  }

  Future<void> _redial() async {
    if (!mounted || _isDisposed) return;
    _releaseOutgoingLock();

    _shouldDisposeWebRtcOnDispose = true;
    _shouldClearActiveCallOnDispose = true;

    await callService.disposeAll();
    CallNotificationService.clearActiveCall();
    _shouldDisposeWebRtcOnDispose = false;
    _shouldClearActiveCallOnDispose = false;
    await _resetPostCallAudio();
    _shouldResetAudioOnDispose = false;

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          contactName: _displayName,
          receiverId: widget.receiverId,
          isVideo: widget.isVideo,
          isCaller: true,
        ),
      ),
    );
  }

  void _openChatWhileCalling() {
    if (_isDisposed || widget.receiverId.trim().isEmpty || callId == null) {
      return;
    }

    unawaited(_setNativePictureInPictureEnabled(false));

    Navigator.of(context)
        .push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactName: _displayName,
          phone: widget.receiverId,
          chatType: 'online',
          receiverId: widget.receiverId,
          openedFromActiveCall: true,
        ),
      ),
    )
        .whenComplete(() {
      if (!_isDisposed) {
        unawaited(_syncNativePictureInPictureEligibility());
      }
    });
  }

  Future<void> _minimizeToChat() async {
    await _enterPictureInPicture();
  }

  void _toggleMute() {
    setState(() => isMuted = !isMuted);
    callService.setMuted(isMuted);
  }

  Future<void> _toggleCamera() async {
    final hasReadyLocalStream = callService.localStream != null;
    final hasLocalVideoTrack =
        callService.localStream?.getVideoTracks().isNotEmpty ?? false;
    final canTurnOnCamera = hasReadyLocalStream;
    final canTurnOffCamera = hasLocalVideoTrack;

    if ((isCameraOff && !canTurnOnCamera) ||
        (!isCameraOff && !canTurnOffCamera)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera is still getting ready. Please try again.'),
        ),
      );
      return;
    }

    final nextValue = !isCameraOff;
    setState(() => isCameraOff = nextValue);

    try {
      await callService.setCameraOff(nextValue);
    } catch (e) {
      if (!mounted) return;
      setState(() => isCameraOff = !nextValue);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not update camera: $e')),
      );
    }
  }

  void _switchCamera() {
    final videoTracks = callService.localStream?.getVideoTracks() ?? const [];
    if (videoTracks.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Camera is still getting ready. Please try again.'),
        ),
      );
      return;
    }

    setState(() => isFrontCamera = !isFrontCamera);
    for (final track in videoTracks) {
      Helper.switchCamera(track);
    }
  }

  Future<void> _toggleVideo() async {
    final enableVideo = !isVideoEnabled;

    if (enableVideo &&
        (callService.localStream?.getVideoTracks().isEmpty ?? true)) {
      var cameraStatus = await Permission.camera.status;
      if (!cameraStatus.isGranted) {
        cameraStatus = await Permission.camera.request();
      }

      if (!cameraStatus.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Camera permission is required.')),
          );
        }
        return;
      }
    }

    setState(() => isVideoEnabled = enableVideo);

    if (enableVideo) {
      try {
        await callService.enableVideo();
        setState(() {
          isCameraOff = false;
          _audioOutput = 'speaker';
        });
        await _setAudioOutput(speaker: true);
        await _syncNativePictureInPictureEligibility();
      } catch (e) {
        setState(() => isVideoEnabled = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not start camera: $e')),
          );
        }
      }
    } else {
      await callService.disableVideo();
      await _syncNativePictureInPictureEligibility();
    }
  }

  Widget _buildAvatar({double radius = 50}) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: Colors.white24,
      child: Text(
        _displayName.isNotEmpty ? _displayName[0].toUpperCase() : '?',
        style: TextStyle(
          fontSize: radius * 0.85,
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color? activeColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 26,
            backgroundColor:
                active ? (activeColor ?? Colors.white) : Colors.white24,
            child: Icon(
              icon,
              color: active ? Colors.black87 : Colors.white,
              size: 22,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildEndBtn(VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 32,
            backgroundColor: Colors.redAccent,
            child: Icon(Icons.call_end, color: Colors.white, size: 28),
          ),
          SizedBox(height: 5),
          Text(
            'End',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildCallEndedUI() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1A1A2E),
            Color(0xFF16213E),
            Color(0xFF0F3460),
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _buildAvatar(radius: 56),
            const SizedBox(height: 24),
            Text(
              _displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _endedBy == 'them'
                    ? '$_displayName ended the call'
                    : _endedBy == 'busy'
                        ? '$_displayName is busy'
                        : 'Call ended',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.timer_outlined,
                    color: Colors.white54, size: 16),
                const SizedBox(width: 6),
                Text(
                  _callSeconds > 0
                      ? 'Duration: $_callDuration'
                      : 'Call not connected',
                  style: const TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 60),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  GestureDetector(
                    onTap: () async {
                      _shouldDisposeWebRtcOnDispose = true;
                      _shouldClearActiveCallOnDispose = true;
                      await callService.disposeAll();
                      CallNotificationService.clearActiveCall();
                      _shouldDisposeWebRtcOnDispose = false;
                      _shouldClearActiveCallOnDispose = false;
                      await _resetPostCallAudio();
                      _shouldResetAudioOnDispose = false;
                      if (mounted) Navigator.pop(context);
                    },
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 30,
                          backgroundColor: Colors.white24,
                          child:
                              Icon(Icons.close, color: Colors.white, size: 26),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Close',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: _redial,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 30,
                          backgroundColor: Color(0xFF25D366),
                          child:
                              Icon(Icons.phone, color: Colors.white, size: 26),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Redial',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIncomingUI() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1A1A2E),
            Color(0xFF16213E),
            Color(0xFF0F3460),
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 50),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                widget.isVideo
                    ? '📹 Incoming Video Call'
                    : '📞 Incoming Voice Call',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
            const SizedBox(height: 40),
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (_, child) => Transform.scale(
                scale: _pulseAnimation.value,
                child: child,
              ),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white30, width: 2),
                ),
                child: _buildAvatar(radius: 56),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              statusText,
              style: const TextStyle(color: Colors.white60, fontSize: 15),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 48),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  GestureDetector(
                    onTap: _declineCall,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 32,
                          backgroundColor: Colors.redAccent,
                          child: Icon(Icons.call_end,
                              color: Colors.white, size: 28),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Decline',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: _acceptCall,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircleAvatar(
                          radius: 32,
                          backgroundColor: Color(0xFF25D366),
                          child:
                              Icon(Icons.call, color: Colors.white, size: 28),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Accept',
                          style: TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceCallUI() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1A1A2E),
            Color(0xFF16213E),
            Color(0xFF0F3460),
          ],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            _buildAvatar(radius: 64),
            const SizedBox(height: 24),
            Text(
              _displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (isLoading)
              Column(
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: Colors.white54,
                      strokeWidth: 2,
                    ),
                  ),
                  if (_isReconnecting) ...[
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.orange.withValues(alpha: 0.5),
                        ),
                      ),
                      child: const Text(
                        'Reconnecting...',
                        style: TextStyle(
                          color: Colors.orangeAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              )
            else
              Text(
                statusText == 'Connected' ? _callDuration : statusText,
                style: const TextStyle(color: Colors.white60, fontSize: 15),
              ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildControlBtn(
                        icon: Icons.arrow_back,
                        label: 'Chat',
                        onTap: _openChatWhileCalling,
                      ),
                      _buildControlBtn(
                        icon: isMuted ? Icons.mic_off : Icons.mic,
                        label: isMuted ? 'Unmute' : 'Mute',
                        onTap: _toggleMute,
                        active: isMuted,
                      ),
                      _buildControlBtn(
                        icon: _audioIcon,
                        label: _audioLabel,
                        onTap: _cycleAudioOutput,
                        active: _audioOutput == 'speaker',
                      ),
                      _buildControlBtn(
                        icon: isVideoEnabled
                            ? Icons.videocam
                            : Icons.videocam_off,
                        label: isVideoEnabled ? 'Cam On' : 'Cam Off',
                        onTap: _toggleVideo,
                        active: isVideoEnabled,
                        activeColor: const Color(0xFF25D366),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildEndBtn(_endCall),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  bool get _showRemoteVideo =>
      callService.hasRemoteVideoTrack ||
      (!isRemoteCameraOff && isVideoEnabled);

  Widget _buildVideoCallUI() {
    if (_isInPictureInPictureMode) {
      return Stack(
        fit: StackFit.expand,
        children: [
          if (!_showRemoteVideo)
            Container(
              color: Colors.black,
              child: Center(child: _buildAvatar(radius: 34)),
            )
          else
            RTCVideoView(
              callService.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
              mirror: false,
            ),
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                '$_displayName ${statusText == 'Connected' ? _callDuration : statusText}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (!_showRemoteVideo)
          Container(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildAvatar(radius: 48),
                  const SizedBox(height: 16),
                  const Icon(
                    Icons.videocam_off,
                    color: Colors.white54,
                    size: 34,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$_displayName turned off their camera',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          RTCVideoView(
            callService.remoteRenderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            mirror: false,
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.55),
                  Colors.transparent,
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.75),
                ],
                stops: const [0.0, 0.18, 0.65, 1.0],
              ),
            ),
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: _openChatWhileCalling,
                    icon: const Icon(
                      Icons.chat_bubble_outline,
                      color: Colors.white,
                    ),
                  ),
                  _buildAvatar(radius: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _displayName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black)
                            ],
                          ),
                        ),
                        Text(
                          statusText == 'Connected'
                              ? _callDuration
                              : statusText,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black)
                            ],
                          ),
                        ),
                        if (isRemoteMuted)
                          const Text(
                            'Muted',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                              shadows: [
                                Shadow(blurRadius: 4, color: Colors.black),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: _minimizeToChat,
                    icon: const Icon(
                      Icons.picture_in_picture_alt,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 140,
          width: 110,
          height: 160,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: isCameraOff
                ? Container(
                    color: Colors.black54,
                    child: const Center(
                      child: Icon(
                        Icons.videocam_off,
                        color: Colors.white54,
                        size: 32,
                      ),
                    ),
                  )
                : RTCVideoView(
                    callService.localRenderer,
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
          ),
        ),
        if (isLoading)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: Colors.white),
                if (_isReconnecting) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: Colors.orange.withValues(alpha: 0.45),
                      ),
                    ),
                    child: const Text(
                      'Reconnecting...',
                      style: TextStyle(
                        color: Colors.orangeAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildControlBtn(
                    icon: isMuted ? Icons.mic_off : Icons.mic,
                    label: isMuted ? 'Unmute' : 'Mute',
                    onTap: _toggleMute,
                    active: isMuted,
                  ),
                  _buildControlBtn(
                    icon: isCameraOff ? Icons.videocam_off : Icons.videocam,
                    label: isCameraOff ? 'Cam Off' : 'Cam On',
                    onTap: _toggleCamera,
                    active: isCameraOff,
                  ),
                  _buildEndBtn(_endCall),
                  _buildControlBtn(
                    icon: Icons.flip_camera_android,
                    label: 'Flip',
                    onTap: _switchCamera,
                  ),
                  _buildControlBtn(
                    icon: _audioIcon,
                    label: _audioLabel,
                    onTap: _cycleAudioOutput,
                    active: _audioOutput == 'speaker',
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_callEnded) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: _buildCallEndedUI(),
      );
    }

    Widget body;
    if (!widget.isCaller && !callAnswered) {
      body = _buildIncomingUI();
    } else if (isVideoEnabled && callAnswered) {
      body = _buildVideoCallUI();
    } else {
      body = _buildVoiceCallUI();
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {},
      child: Scaffold(
        backgroundColor: Colors.black,
        body: body,
      ),
    );
  }
}
