// ignore_for_file: avoid_print, deprecated_member_use, unnecessary_this, unused_field

import 'dart:async';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class WebRtcCallService {
  WebRtcCallService._();
  static final WebRtcCallService instance = WebRtcCallService._();

  factory WebRtcCallService() => instance;

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _videoCaptureStream;
  MediaStream? _remoteStream;

  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  RTCRtpSender? _audioSender;
  RTCRtpSender? _videoSender;

  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _callSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ansCandSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _offCandSub;
  final StreamController<String> _runtimeStatusController =
      StreamController<String>.broadcast();
  final StreamController<int> _mediaStateController =
      StreamController<int>.broadcast();
  Timer? _reconnectRetryTimer;

  bool _renderersInit = false;
  bool _disposing = false;
  String? _activeCallId;
  String? _lastPublishedOfferSdp;
  String? _lastHandledRemoteOfferSdp;
  String? _lastPublishedAnswerSdp;
  String? _lastHandledRemoteAnswerSdp;
  String? _lastRuntimeStatus;
  bool _hasReachedConnectedState = false;
  String? _activeParticipantRole;
  bool _isRestartingIce = false;
  int _iceRestartAttempts = 0;
  String? _lastHandledReconnectRequestToken;

  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';

  String get currentUserName =>
      FirebaseAuth.instance.currentUser?.displayName ??
      FirebaseAuth.instance.currentUser?.email ??
      currentUserId;

  MediaStream? get localStream => _localStream;
  Stream<String> get runtimeStatuses => _runtimeStatusController.stream;
  Stream<int> get mediaStateChanges => _mediaStateController.stream;
  bool get hasRemoteVideoTrack =>
      _remoteStream?.getVideoTracks().isNotEmpty ?? false;
  bool get hasRemoteStream =>
      _remoteStream != null || remoteRenderer.srcObject != null;
  bool get hasLocalVideoTrack =>
      _localStream?.getVideoTracks().isNotEmpty ?? false;

  void _log(String message) {
    print('[WebRTC] $message');
  }

  void _notifyMediaStateChanged() {
    if (_mediaStateController.isClosed) return;
    _mediaStateController.add(DateTime.now().microsecondsSinceEpoch);
  }

  String _convKey(String a, String b) =>
      (a.compareTo(b) < 0) ? '${a}_$b' : '${b}_$a';

  Future<void> initRenderers() async {
    if (_renderersInit) return;
    await localRenderer.initialize();
    await remoteRenderer.initialize();
    _renderersInit = true;
  }

  Future<void> _openUserMedia({required bool isVideo}) async {
    await initRenderers();
    _log('openUserMedia start isVideo=$isVideo role=$_activeParticipantRole');

    if (Platform.isAndroid) {
      try {
        await Helper.setAndroidAudioConfiguration(
          AndroidAudioConfiguration.communication,
        );
      } catch (e) {
        _log('setAndroidAudioConfiguration failed: $e');
      }
    }

    final mediaConstraints = {
      // Keep constraints simple for maximum plugin compatibility across
      // Android/iOS; advanced audio constraints can be device/version specific.
      'audio': true,
      'video': isVideo
          ? {
              'facingMode': 'user',
              'width': 640,
              'height': 480,
              'frameRate': 30,
            }
          : false,
    };

    try {
      _localStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
    } catch (e) {
      _log('openUserMedia failed (permission/device?): $e');
      rethrow;
    }
    if (localRenderer.srcObject != _localStream) {
      localRenderer.srcObject = _localStream;
    }
    _notifyMediaStateChanged();
    _log(
      'openUserMedia ready audioTracks=${_localStream?.getAudioTracks().length ?? 0} '
      'videoTracks=${_localStream?.getVideoTracks().length ?? 0}',
    );

    for (final track in _localStream?.getAudioTracks() ?? []) {
      try {
        track.enabled = true;
      } catch (_) {}
      try {
        await Helper.setMicrophoneMute(false, track);
      } catch (_) {}
      try {
        await Helper.setVolume(1.0, track);
      } catch (_) {}
    }
  }

  Future<void> _createPeerConnection() async {
    const config = {
      'iceServers': [
        // STUN — discover public IP (works when NAT is traversable)
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        // TURN relay — required for carrier-grade NAT (mobile data / CGNAT).
        // These are the public OpenRelay servers from metered.ca, suitable for
        // testing. Replace with dedicated metered.ca credentials for production
        // to avoid bandwidth limits and reliability constraints.
        {
          'urls': [
            'turn:openrelay.metered.ca:80',
            'turn:openrelay.metered.ca:80?transport=tcp',
            'turn:openrelay.metered.ca:443',
            'turn:openrelay.metered.ca:443?transport=tcp',
          ],
          'username': 'openrelayproject',
          'credential': 'openrelayproject',
        },
      ],
      'iceCandidatePoolSize': 10,
      'sdpSemantics': 'unified-plan',
    };

    _pc = await createPeerConnection(config);
    _log('peerConnection created');

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        final sender = await _pc!.addTrack(track, _localStream!);
        if (track.kind == 'video') {
          _videoSender = sender;
        } else if (track.kind == 'audio') {
          _audioSender = sender;
        }
        _log('added local track kind=${track.kind} id=${track.id}');
      }
    }

    _pc!.onTrack = (event) {
      unawaited(_bindRemoteTrack(event));
    };
    _pc!.onAddStream = (stream) {
      unawaited(_bindRemoteStream(stream));
    };
    _pc!.onRemoveStream = (stream) {
      if (_remoteStream == stream) {
        _remoteStream = null;
        remoteRenderer.srcObject = null;
        _notifyMediaStateChanged();
      }
    };

    _pc!.onIceConnectionState = (state) {
      _handleTransportState(state.toString());
    };

    _pc!.onConnectionState = (state) {
      _handleTransportState(state.toString());
    };
  }

  Future<void> _bindRemoteTrack(RTCTrackEvent event) async {
    if (event.track.kind != 'video' && event.track.kind != 'audio') {
      return;
    }
    _log(
      'bindRemoteTrack kind=${event.track.kind} id=${event.track.id} '
      'streams=${event.streams.length}',
    );

    try {
      event.track.enabled = true;
    } catch (_) {}
    if (event.track.kind == 'audio') {
      try {
        await Helper.setVolume(1.0, event.track);
      } catch (_) {}
    }

    if (event.streams.isNotEmpty) {
      await _bindRemoteStream(event.streams.first);
      return;
    }

    _remoteStream ??= await createLocalMediaStream('remote_stream');

    final hasTrack = _remoteStream!.getTracks().any(
          (track) => track.id == event.track.id,
        );
    if (!hasTrack) {
      _remoteStream!.addTrack(event.track);
    }

    if (remoteRenderer.srcObject != _remoteStream) {
      remoteRenderer.srcObject = _remoteStream;
    }
    _notifyMediaStateChanged();
    await _ensureRemoteAudioPlayback();
  }

  Future<void> _bindRemoteStream(MediaStream stream) async {
    _remoteStream = stream;
    if (remoteRenderer.srcObject != _remoteStream) {
      remoteRenderer.srcObject = _remoteStream;
    }
    _notifyMediaStateChanged();
    await _ensureRemoteAudioPlayback();
  }

  Future<void> _ensureRemoteAudioPlayback() async {
    final remoteStream = _remoteStream;
    if (remoteStream == null) return;

    for (final track in remoteStream.getAudioTracks()) {
      try {
        track.enabled = true;
      } catch (_) {}
      try {
        await Helper.setVolume(1.0, track);
      } catch (_) {}
    }
  }

  Future<void> _handleTransportState(String stateName) async {
    final normalized = stateName.toLowerCase();
    _log(
      'transportState=$stateName role=$_activeParticipantRole '
      'callId=$_activeCallId connected=$_hasReachedConnectedState',
    );

    if (normalized.contains('connected') || normalized.contains('completed')) {
      _hasReachedConnectedState = true;
      _iceRestartAttempts = 0;
      _isRestartingIce = false;
      _reconnectRetryTimer?.cancel();
      await _ensureRemoteAudioPlayback();
      await _publishRuntimeStatus('connected');
      return;
    }

    if (!normalized.contains('disconnected') &&
        !normalized.contains('failed')) {
      return;
    }

    if (!_hasReachedConnectedState) return;

    if (_activeParticipantRole == 'caller') {
      await _publishRuntimeStatus('reconnecting');
    } else {
      _emitLocalRuntimeStatus('reconnecting');
    }

    if (_activeParticipantRole == 'caller') {
      _scheduleIceRestart(normalized.contains('failed'));
    }
  }

  void _scheduleIceRestart(bool immediate) {
    if (_isRestartingIce) return;
    if (_iceRestartAttempts >= 3) return;
    _log(
        'scheduleIceRestart immediate=$immediate attempts=$_iceRestartAttempts');

    _reconnectRetryTimer?.cancel();
    _reconnectRetryTimer = Timer(
      Duration(milliseconds: immediate ? 400 : 1500),
      () => _attemptIceRestart(),
    );
  }

  Future<void> _attemptIceRestart() async {
    final pc = _pc;
    final callId = _activeCallId;
    if (_disposing || pc == null || callId == null || callId.isEmpty) return;
    if (_isRestartingIce) return;
    if (_iceRestartAttempts >= 3) return;
    if (_activeParticipantRole != 'caller') return;
    _log(
        'attemptIceRestart start callId=$callId attempts=$_iceRestartAttempts');

    _isRestartingIce = true;
    _iceRestartAttempts++;

    try {
      await pc.restartIce();
      final offer = await pc.createOffer({'iceRestart': true});
      await pc.setLocalDescription(offer);
      _lastPublishedOfferSdp = offer.sdp;

      await _db.collection('calls').doc(callId).set({
        'offer': offer.toMap(),
        'status': 'reconnecting',
        'reconnectRequestedBy': FieldValue.delete(),
        'reconnectRequestedAt': FieldValue.delete(),
      }, SetOptions(merge: true));
      _log('attemptIceRestart published offer for callId=$callId');
    } catch (e) {
      _log('ICE restart failed: $e');
    } finally {
      _isRestartingIce = false;
    }
  }

  Future<void> requestRecovery() async {
    final pc = _pc;
    final callId = _activeCallId;
    if (_disposing || pc == null || callId == null || callId.isEmpty) return;
    _log('requestRecovery role=$_activeParticipantRole callId=$callId');

    if (_activeParticipantRole == 'caller') {
      await _publishRuntimeStatus('reconnecting');
    } else {
      _emitLocalRuntimeStatus('reconnecting');
    }

    if (_activeParticipantRole == 'caller') {
      _scheduleIceRestart(true);
      return;
    }

    try {
      await pc.restartIce();
      await _db.collection('calls').doc(callId).set({
        'status': 'reconnecting',
        'reconnectRequestedBy': currentUserId,
        'reconnectRequestedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      _log('requestRecovery published reconnect request for callId=$callId');
    } catch (e) {
      _log('restartIce request failed: $e');
    }
  }

  void _emitLocalRuntimeStatus(String status) {
    if (_lastRuntimeStatus == status) return;
    _lastRuntimeStatus = status;
    _runtimeStatusController.add(status);
  }

  Future<void> _publishRuntimeStatus(String status) async {
    final callId = _activeCallId;
    if (_disposing || callId == null || callId.isEmpty) return;
    _log('publishRuntimeStatus status=$status callId=$callId');
    if (_lastRuntimeStatus != status) {
      _runtimeStatusController.add(status);
    }
    if (_lastRuntimeStatus == status) return;

    try {
      final callRef = _db.collection('calls').doc(callId);
      final snap = await callRef.get();
      final currentStatus = snap.data()?['status'] as String?;

      if (currentStatus == 'ended' ||
          currentStatus == 'declined' ||
          currentStatus == 'missed' ||
          currentStatus == 'cancelled') {
        return;
      }

      if (currentStatus == status) {
        _lastRuntimeStatus = status;
        return;
      }

      final updates = <String, dynamic>{
        'status': status,
      };
      if (status == 'connected') {
        updates['reconnectRequestedBy'] = FieldValue.delete();
        updates['reconnectRequestedAt'] = FieldValue.delete();
      }

      await callRef.set(updates, SetOptions(merge: true));

      _lastRuntimeStatus = status;
    } catch (e) {
      _log('publish runtime status failed: $e');
    }
  }

  String _localFieldName(String suffix) {
    final role = _activeParticipantRole == 'callee' ? 'callee' : 'caller';
    return '${role}_$suffix';
  }

  Future<void> _syncLocalMediaState({
    bool? micMuted,
    bool? cameraOff,
    bool? videoEnabled,
  }) async {
    final callId = _activeCallId;
    if (_disposing || callId == null || callId.isEmpty) return;

    final updates = <String, dynamic>{};
    if (micMuted != null) {
      updates[_localFieldName('micMuted')] = micMuted;
    }
    if (cameraOff != null) {
      updates[_localFieldName('cameraOff')] = cameraOff;
    }
    if (videoEnabled != null) {
      updates[_localFieldName('videoEnabled')] = videoEnabled;
    }

    if (updates.isEmpty) return;

    try {
      await _db.collection('calls').doc(callId).set(
            updates,
            SetOptions(merge: true),
          );
    } catch (e) {
      print('[WebRTC] sync media state failed: $e');
    }
  }

  Future<void> _renegotiateCurrentMedia() async {
    final pc = _pc;
    final callId = _activeCallId;
    if (_disposing || pc == null || callId == null || callId.isEmpty) return;

    try {
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _lastPublishedOfferSdp = offer.sdp;
      _log('renegotiateCurrentMedia published new offer callId=$callId');

      await _db.collection('calls').doc(callId).set({
        'offer': offer.toMap(),
      }, SetOptions(merge: true));
    } catch (e) {
      _log('renegotiation failed: $e');
    }
  }

  Future<RTCRtpSender?> _findSenderByKind(String kind) async {
    final pc = _pc;
    if (pc == null) return null;

    if (kind == 'video' && _videoSender != null) {
      return _videoSender;
    }

    if (kind == 'audio' && _audioSender != null) {
      return _audioSender;
    }

    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == kind) {
        if (kind == 'video') {
          _videoSender = sender;
        } else if (kind == 'audio') {
          _audioSender = sender;
        }
        return sender;
      }
    }
    return null;
  }

  Future<void> _disposeVideoCaptureStream() async {
    try {
      for (final track in _videoCaptureStream?.getTracks() ?? []) {
        try {
          track.stop();
        } catch (_) {}
      }
      await _videoCaptureStream?.dispose();
    } catch (_) {}
    _videoCaptureStream = null;
  }

  Future<void> _removeLocalVideoTracks() async {
    final localStream = _localStream;
    if (localStream == null) return;

    final tracks = List<MediaStreamTrack>.from(localStream.getVideoTracks());
    for (final track in tracks) {
      try {
        track.enabled = false;
      } catch (_) {}
      try {
        await localStream.removeTrack(track);
      } catch (_) {}
      try {
        track.stop();
      } catch (_) {}
    }
  }

  Future<void> _attachFreshVideoTrack({
    required bool markCallAsVideo,
  }) async {
    final localStream = _localStream;
    final pc = _pc;
    if (localStream == null || pc == null) {
      throw StateError('Local stream is not ready');
    }

    await _removeLocalVideoTracks();
    await _disposeVideoCaptureStream();

    final videoStream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'user',
        'width': 640,
        'height': 480,
        'frameRate': 30,
      },
    });

    _videoCaptureStream = videoStream;
    final newTracks = videoStream.getVideoTracks();
    if (newTracks.isEmpty) {
      throw StateError('Camera track could not be created');
    }

    final videoTrack = newTracks.first;
    videoTrack.enabled = true;
    localStream.addTrack(videoTrack);
    if (localRenderer.srcObject != localStream) {
      localRenderer.srcObject = localStream;
    }
    _notifyMediaStateChanged();

    final sender = await _findSenderByKind('video');
    if (sender != null) {
      await sender.replaceTrack(videoTrack);
    } else {
      _videoSender = await pc.addTrack(videoTrack, localStream);
    }

    final updates = <String, dynamic>{
      'offer': FieldValue.delete(),
    };
    if (markCallAsVideo) {
      updates['isVideo'] = true;
    }

    final callId = _activeCallId;
    if (callId != null && callId.isNotEmpty) {
      await _db.collection('calls').doc(callId).set(
            updates,
            SetOptions(merge: true),
          );
    }

    await _syncLocalMediaState(
      cameraOff: false,
      videoEnabled: true,
    );
    await _renegotiateCurrentMedia();
  }

  Future<void> _clearCandidates(String callId) async {
    final callDoc = _db.collection('calls').doc(callId);

    try {
      final offerSnap = await callDoc.collection('offerCandidates').get();
      for (final d in offerSnap.docs) {
        await d.reference.delete();
      }
    } catch (e) {
      print('[WebRTC] clear offerCandidates failed: $e');
    }

    try {
      final answerSnap = await callDoc.collection('answerCandidates').get();
      for (final d in answerSnap.docs) {
        await d.reference.delete();
      }
    } catch (e) {
      print('[WebRTC] clear answerCandidates failed: $e');
    }
  }

  Future<String> makeCall({
    String? callId,
    required String callerId,
    required String calleeId,
    required bool isVideo,
  }) async {
    if (_pc != null ||
        _localStream != null ||
        _remoteStream != null ||
        _activeCallId != null ||
        _callSub != null ||
        _ansCandSub != null ||
        _offCandSub != null) {
      await disposeAll();
    }

    final String newCallId = _db.collection('calls').doc().id;
    final String convKey = _convKey(callerId, calleeId);

    await _db.collection('calls').doc(newCallId).set({
      'callId': newCallId,
      'convKey': convKey,
      'callerId': callerId,
      'callerName': currentUserName,
      'calleeId': calleeId,
      'isVideo': isVideo,
      'caller_micMuted': false,
      'caller_cameraOff': !isVideo,
      'caller_videoEnabled': isVideo,
      'callee_micMuted': false,
      'callee_cameraOff': !isVideo,
      'callee_videoEnabled': isVideo,
      'status': 'ringing',
      'createdAt': FieldValue.serverTimestamp(),
      'offer': FieldValue.delete(),
      'answer': FieldValue.delete(),
    }, SetOptions(merge: true));
    _log(
        'makeCall initialized callDoc callId=$newCallId calleeId=$calleeId isVideo=$isVideo');

    await _clearCandidates(newCallId);

    await _openUserMedia(isVideo: isVideo);
    await _createPeerConnection();

    _pc!.onIceCandidate = (c) async {
      if (c.candidate == null) return;
      try {
        await _db
            .collection('calls')
            .doc(newCallId)
            .collection('offerCandidates')
            .add(c.toMap());
      } catch (e) {
        _log('write offerCandidate failed: $e');
      }
    };

    final offer = await _pc!.createOffer();
    await _pc!.setLocalDescription(offer);
    _activeCallId = newCallId;
    _lastPublishedOfferSdp = offer.sdp;
    _lastHandledRemoteOfferSdp = null;
    _lastPublishedAnswerSdp = null;
    _lastHandledRemoteAnswerSdp = null;
    _lastRuntimeStatus = 'ringing';
    _hasReachedConnectedState = false;
    _activeParticipantRole = 'caller';
    _iceRestartAttempts = 0;
    _isRestartingIce = false;

    await _db.collection('calls').doc(newCallId).set({
      'offer': offer.toMap(),
    }, SetOptions(merge: true));
    _log('makeCall offer published callId=$newCallId');

    return newCallId;
  }

  Future<void> answerCall({
    required String callId,
    required bool isVideo,
  }) async {
    if (_pc != null ||
        _localStream != null ||
        _remoteStream != null ||
        _activeCallId != null ||
        _callSub != null ||
        _ansCandSub != null ||
        _offCandSub != null) {
      await disposeAll();
    }

    final callDoc = _db.collection('calls').doc(callId);
    final callData = (await callDoc.get()).data();
    if (callData == null) return;
    _log('answerCall start callId=$callId isVideo=$isVideo');

    await _openUserMedia(isVideo: isVideo);
    await _createPeerConnection();

    _pc!.onIceCandidate = (c) async {
      if (c.candidate == null) return;
      try {
        await callDoc.collection('answerCandidates').add(c.toMap());
      } catch (e) {
        _log('write answerCandidate failed: $e');
      }
    };

    final offer = callData['offer'];
    if (offer == null || offer['sdp'] == null || offer['type'] == null) {
      print('[WebRTC] Missing offer in call doc $callId');
      return;
    }

    await _pc!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'], offer['type']),
    );

    final answer = await _pc!.createAnswer();
    await _pc!.setLocalDescription(answer);
    _activeCallId = callId;
    _lastHandledRemoteOfferSdp = offer['sdp'] as String?;
    _lastPublishedAnswerSdp = answer.sdp;
    _lastPublishedOfferSdp = null;
    _lastHandledRemoteAnswerSdp = null;
    _lastRuntimeStatus = 'connected';
    _hasReachedConnectedState = false;
    _activeParticipantRole = 'callee';
    _iceRestartAttempts = 0;
    _isRestartingIce = false;

    await callDoc.set({
      'answer': answer.toMap(),
      'status': 'connected',
      'callee_micMuted': false,
      'callee_cameraOff': !isVideo,
      'callee_videoEnabled': isVideo,
    }, SetOptions(merge: true));
    _log('answerCall answer published callId=$callId');
  }

  Future<void> _listenForCallUpdates(String callId) async {
    await _callSub?.cancel();

    final callDoc = _db.collection('calls').doc(callId);

    _callSub = callDoc.snapshots().listen((snap) async {
      final data = snap.data();
      if (data == null) return;

      try {
        if (_activeParticipantRole == 'callee') {
          await _handleRemoteOfferUpdate(callId, data['offer']);
        } else if (_activeParticipantRole == 'caller') {
          await _handleRemoteAnswerUpdate(data['answer']);
        }

        await _handleReconnectSignal(callId, data);
      } catch (e) {
        _log('call updates handler failed: $e');
      }
    }, onError: (e) {
      _log('callDoc snapshots error: $e');
    });
  }

  Future<void> _handleReconnectSignal(
    String callId,
    Map<String, dynamic> data,
  ) async {
    if (_activeParticipantRole != 'caller') return;

    final requester = data['reconnectRequestedBy'] as String?;
    final requestedAt = data['reconnectRequestedAt'];
    if (requester == null || requester.isEmpty || requester == currentUserId) {
      return;
    }

    final token =
        '$requester|${requestedAt is Timestamp ? requestedAt.millisecondsSinceEpoch : requestedAt.toString()}';
    if (_lastHandledReconnectRequestToken == token) return;

    _lastHandledReconnectRequestToken = token;
    _log('handleReconnectSignal requester=$requester callId=$callId');
    _scheduleIceRestart(true);
  }

  Future<void> _handleRemoteOfferUpdate(
    String callId,
    dynamic offer,
  ) async {
    final pc = _pc;
    if (pc == null || offer is! Map) return;

    // Only the callee should ever process offers from Firestore. The caller is
    // the offerer in this app's signaling flow (including ICE restarts).
    if (_activeParticipantRole != 'callee') return;

    final sdp = offer['sdp'];
    final type = offer['type'];
    if (sdp is! String || sdp.isEmpty || type is! String || type.isEmpty) {
      return;
    }

    if (sdp == _lastPublishedOfferSdp || sdp == _lastHandledRemoteOfferSdp) {
      return;
    }

    final remoteDesc = await pc.getRemoteDescription();
    if (remoteDesc?.sdp == sdp) {
      _lastHandledRemoteOfferSdp = sdp;
      return;
    }

    final signalingState = await pc.getSignalingState();
    if (signalingState != null &&
        signalingState != RTCSignalingState.RTCSignalingStateStable) {
      _log('skip remote offer (signalingState=$signalingState)');
      return;
    }

    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _lastHandledRemoteOfferSdp = sdp;

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _lastPublishedAnswerSdp = answer.sdp;

    try {
      await _db.collection('calls').doc(callId).set({
        'answer': answer.toMap(),
        'status': 'connected',
      }, SetOptions(merge: true));
    } catch (e) {
      _log('publish answer failed: $e');
    }
  }

  Future<void> _handleRemoteAnswerUpdate(dynamic answer) async {
    final pc = _pc;
    if (pc == null || answer is! Map) return;

    // Only the caller should ever process answers from Firestore. The callee
    // is the answerer, and applying its own answer as "remote" breaks signaling.
    if (_activeParticipantRole != 'caller') return;

    final sdp = answer['sdp'];
    final type = answer['type'];
    if (sdp is! String || sdp.isEmpty || type is! String || type.isEmpty) {
      return;
    }

    if (sdp == _lastPublishedAnswerSdp || sdp == _lastHandledRemoteAnswerSdp) {
      return;
    }

    final remoteDesc = await pc.getRemoteDescription();
    if (remoteDesc?.sdp == sdp) {
      _lastHandledRemoteAnswerSdp = sdp;
      return;
    }

    final signalingState = await pc.getSignalingState();
    if (signalingState != null &&
        signalingState != RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      _log('skip remote answer (signalingState=$signalingState)');
      return;
    }

    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _lastHandledRemoteAnswerSdp = sdp;
  }

  Future<void> listenForAnswer(String callId) async {
    await _ansCandSub?.cancel();
    await _listenForCallUpdates(callId);

    final callDoc = _db.collection('calls').doc(callId);

    _ansCandSub = callDoc.collection('answerCandidates').snapshots().listen(
        (snapshot) async {
      final pc = _pc;
      if (pc == null) return;

      for (final change in snapshot.docChanges) {
        if (change.type != DocumentChangeType.added) continue;

        final d = change.doc.data();
        if (d == null) continue;

        final cand = d['candidate'];
        final mid = d['sdpMid'];
        final lineIndex = d['sdpMLineIndex'];

        if (cand is! String || cand.isEmpty) continue;
        if (mid != null && mid is! String) continue;
        if (lineIndex != null && lineIndex is! int) continue;

        try {
          await pc.addCandidate(
            RTCIceCandidate(cand, mid as String?, lineIndex as int?),
          );
        } catch (e) {
          _log('addCandidate(answer) failed: $e');
        }
      }
    }, onError: (e) {
      _log('answerCandidates snapshots error: $e');
    });
  }

  Future<void> listenForOfferCandidates(String callId) async {
    await _offCandSub?.cancel();
    await _listenForCallUpdates(callId);

    final callDoc = _db.collection('calls').doc(callId);

    _offCandSub = callDoc.collection('offerCandidates').snapshots().listen(
        (snapshot) async {
      final pc = _pc;
      if (pc == null) return;

      for (final change in snapshot.docChanges) {
        if (change.type != DocumentChangeType.added) continue;

        final d = change.doc.data();
        if (d == null) continue;

        final cand = d['candidate'];
        final mid = d['sdpMid'];
        final lineIndex = d['sdpMLineIndex'];

        if (cand is! String || cand.isEmpty) continue;
        if (mid != null && mid is! String) continue;
        if (lineIndex != null && lineIndex is! int) continue;

        try {
          await pc.addCandidate(
            RTCIceCandidate(cand, mid as String?, lineIndex as int?),
          );
        } catch (e) {
          _log('addCandidate(offer) failed: $e');
        }
      }
    }, onError: (e) {
      _log('offerCandidates snapshots error: $e');
    });
  }

  Future<void> enableVideo() async {
    if (_localStream == null || _pc == null) {
      throw StateError('Local stream is not ready');
    }
    await _attachFreshVideoTrack(markCallAsVideo: true);
  }

  Future<void> disableVideo() async {
    final sender = await _findSenderByKind('video');
    if (sender != null) {
      await sender.replaceTrack(null);
    }
    await _removeLocalVideoTracks();
    await _disposeVideoCaptureStream();
    if (localRenderer.srcObject != _localStream) {
      localRenderer.srcObject = _localStream;
    }
    _notifyMediaStateChanged();
    await _syncLocalMediaState(
      cameraOff: true,
      videoEnabled: false,
    );
    await _renegotiateCurrentMedia();
  }

  Future<void> setMuted(bool muted) async {
    for (final track in _localStream?.getAudioTracks() ?? []) {
      track.enabled = !muted;
      try {
        await Helper.setMicrophoneMute(muted, track);
      } catch (_) {}
    }
    await _syncLocalMediaState(micMuted: muted);
  }

  Future<void> setCameraOff(bool cameraOff) async {
    if (cameraOff) {
      final sender = await _findSenderByKind('video');
      if (sender != null) {
        await sender.replaceTrack(null);
      }
      await _removeLocalVideoTracks();
      await _disposeVideoCaptureStream();
      if (localRenderer.srcObject != _localStream) {
        localRenderer.srcObject = _localStream;
      }
      _notifyMediaStateChanged();
      await _syncLocalMediaState(
        cameraOff: true,
        videoEnabled: false,
      );
      await _renegotiateCurrentMedia();
      return;
    }

    await _attachFreshVideoTrack(markCallAsVideo: false);
  }

  Future<void> declineCall(String callId) async {
    await _db.collection('calls').doc(callId).set({
      'status': 'declined',
    }, SetOptions(merge: true));

    await _clearCandidates(callId);
    await disposeAll();
  }

  Future<void> endCall(String callId) async {
    await _db.collection('calls').doc(callId).set({
      'status': 'ended',
    }, SetOptions(merge: true));

    await _clearCandidates(callId);
    await disposeAll();
  }

  Future<void> disposeAll() async {
    if (_disposing) return;
    _disposing = true;
    _log(
      'disposeAll start activeCallId=$_activeCallId role=$_activeParticipantRole '
      'local=${_localStream != null} remote=${_remoteStream != null}',
    );

    try {
      await _callSub?.cancel();
      await _ansCandSub?.cancel();
      await _offCandSub?.cancel();
      _reconnectRetryTimer?.cancel();
    } catch (_) {}

    try {
      localRenderer.srcObject = null;
      remoteRenderer.srcObject = null;
      _notifyMediaStateChanged();
    } catch (_) {}

    try {
      await Helper.clearAndroidCommunicationDevice();
    } catch (_) {}

    try {
      await _pc?.close();
    } catch (_) {}

    try {
      for (final t in _localStream?.getTracks() ?? []) {
        try {
          t.enabled = false;
        } catch (_) {}
        try {
          t.stop();
        } catch (_) {}
      }
      await _localStream?.dispose();
    } catch (_) {}

    try {
      for (final t in _videoCaptureStream?.getTracks() ?? []) {
        try {
          t.stop();
        } catch (_) {}
      }
      await _videoCaptureStream?.dispose();
    } catch (_) {}

    try {
      for (final t in _remoteStream?.getTracks() ?? []) {
        try {
          t.stop();
        } catch (_) {}
      }
      await _remoteStream?.dispose();
    } catch (_) {}

    _pc = null;
    _localStream = null;
    _videoCaptureStream = null;
    _remoteStream = null;
    _activeCallId = null;
    _lastPublishedOfferSdp = null;
    _lastHandledRemoteOfferSdp = null;
    _lastPublishedAnswerSdp = null;
    _lastHandledRemoteAnswerSdp = null;
    _lastRuntimeStatus = null;
    _hasReachedConnectedState = false;
    _activeParticipantRole = null;
    _iceRestartAttempts = 0;
    _isRestartingIce = false;
    _lastHandledReconnectRequestToken = null;
    _audioSender = null;
    _videoSender = null;
    _disposing = false;
    _notifyMediaStateChanged();
    _log('disposeAll completed');
  }
}
