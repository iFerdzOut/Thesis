// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/detection_result_model.dart';
import '../models/safety_status.dart';
import '../models/screened_message_model.dart';
import 'native_channel_router.dart';
import 'notification_service.dart';
import 'feedback_database_service.dart';
import 'local_detection_repository.dart';
import 'message_routing_service.dart';
import 'message_screening_service.dart';
import 'sms_storage_service.dart';
import 'smishing_detection_pipeline_service.dart';
import 'url_extraction_service.dart';

class SmsCapabilityState {
  final bool isDefault;
  final bool roleAvailable;
  final bool roleHeld;
  final bool readSmsGranted;
  final bool sendSmsGranted;
  final bool receiveSmsGranted;
  final bool canUseSmsFeatures;

  const SmsCapabilityState({
    required this.isDefault,
    required this.roleAvailable,
    required this.roleHeld,
    required this.readSmsGranted,
    required this.sendSmsGranted,
    required this.receiveSmsGranted,
    required this.canUseSmsFeatures,
  });

  const SmsCapabilityState.unknown()
      : isDefault = false,
        roleAvailable = false,
        roleHeld = false,
        readSmsGranted = false,
        sendSmsGranted = false,
        receiveSmsGranted = false,
        canUseSmsFeatures = false;

  factory SmsCapabilityState.fromMap(Map<String, dynamic> map) {
    return SmsCapabilityState(
      isDefault: map['isDefault'] == true,
      roleAvailable: map['roleAvailable'] != false,
      roleHeld: map['roleHeld'] == true,
      readSmsGranted: map['readSmsGranted'] == true,
      sendSmsGranted: map['sendSmsGranted'] == true,
      receiveSmsGranted: map['receiveSmsGranted'] == true,
      canUseSmsFeatures: map['canUseSmsFeatures'] == true,
    );
  }
}

class SmsRescanSummary {
  const SmsRescanSummary({
    required this.rescannedVisible,
    required this.rescannedQuarantine,
    required this.movedToQuarantine,
    required this.restoredToInbox,
    required this.keptVisible,
    required this.keptQuarantined,
    required this.errors,
    required this.elapsed,
  });

  final int rescannedVisible;
  final int rescannedQuarantine;
  final int movedToQuarantine;
  final int restoredToInbox;
  final int keptVisible;
  final int keptQuarantined;
  final int errors;
  final Duration elapsed;

  int get totalRescanned => rescannedVisible + rescannedQuarantine;
}

class SmsService {
  static const MethodChannel _channel = NativeChannelRouter.channel;
  static final MessageScreeningService _screeningService =
      MessageScreeningService();
  static final SmishingDetectionPipelineService _pipelineService =
      SmishingDetectionPipelineService();
  static const MessageRoutingService _routingService = MessageRoutingService();
  static final LocalDetectionRepository _detectionRepository =
      LocalDetectionRepository();
  static final SmsStorageService _storage = SmsStorageService();
  static final UrlExtractionService _urlExtractionService =
      UrlExtractionService();
  static final ValueNotifier<SmsCapabilityState> capabilityState =
      ValueNotifier<SmsCapabilityState>(const SmsCapabilityState.unknown());

  static int? _incomingSmsHandlerId;
  static int? _screenIncomingSmsHandlerId;
  static int? _smsNotificationIntentHandlerId;
  static int? _smsRoleChangedHandlerId;
  static int? _smsSendStatusHandlerId;
  static int? _smsSyncUpdatedHandlerId;
  static int? _smsComposeIntentHandlerId;

  static Future<void>? _refreshFuture;
  static Future<void>? _pendingEventDrainFuture;
  static Future<void>? _screeningWarmUpFuture;
  static Future<void>? _primeInboxFuture;
  static Future<void>? _maintenanceFuture;
  static Future<void>? _urlExtractorUpgradeSweepFuture;
  static final Map<String, Future<void>> _threadPrimeFutures =
      <String, Future<void>>{};
  static Timer? _maintenanceTimer;
  static bool _initialized = false;
  static Map<String, dynamic>? _pendingSmsNotificationIntent;
  static Map<String, dynamic>? _pendingSmsComposeIntent;
  static int _smsExperienceDepth = 0;
  static final LinkedHashSet<String> _handledEventIds = LinkedHashSet<String>();
  static final Set<String> _confirmedSmishingFeedbackKeys = <String>{};
  static const Duration _maintenanceDelay = Duration(milliseconds: 650);
  static const Duration _threadPrimeCooldown = Duration(seconds: 12);
  static const Duration _urlExtractorUpgradeLookback = Duration(days: 120);
  static const int _maxUrlExtractorUpgradeCandidates = 120;
  static const String _urlExtractorUpgradeSweepKey =
      'sms_url_extractor_upgrade_sweep_v1';

  static void Function({
    required String sender,
    required String body,
    required int timestampMs,
  })? _onSmsNotificationTap;

  static void Function({
    required String phone,
    String? body,
  })? _onSmsComposeIntentTap;

  static bool get _smsExperienceActive => _smsExperienceDepth > 0;

  static void enterSmsExperience() {
    _smsExperienceDepth++;
    unawaited(_warmUpDetectionIfNeeded());
    unawaited(_runUrlExtractorUpgradeSweepIfNeeded());
  }

  static void leaveSmsExperience() {
    if (_smsExperienceDepth > 0) {
      _smsExperienceDepth--;
    }
    if (_smsExperienceDepth == 0) {
      _maintenanceTimer?.cancel();
      _maintenanceTimer = null;
      unawaited(_screeningService.releaseHeavyResources());
    }
  }

  static set onSmsNotificationTap(
    void Function({
      required String sender,
      required String body,
      required int timestampMs,
    })? handler,
  ) {
    _onSmsNotificationTap = handler;
    if (handler != null && _pendingSmsNotificationIntent != null) {
      final args = _pendingSmsNotificationIntent!;
      _pendingSmsNotificationIntent = null;
      unawaited(_dispatchSmsNotificationIntent(args));
    }
  }

  static set onSmsComposeIntentTap(
    void Function({
      required String phone,
      String? body,
    })? handler,
  ) {
    _onSmsComposeIntentTap = handler;
    if (handler != null && _pendingSmsComposeIntent != null) {
      final args = _pendingSmsComposeIntent!;
      _pendingSmsComposeIntent = null;
      _dispatchSmsComposeIntent(args);
    }
  }

  static void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    unawaited(_storage.initialize());

    _incomingSmsHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'onIncomingSmsQueued',
      handler: _handleNativeCall,
    );
    _screenIncomingSmsHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'screenIncomingSms',
      handler: _handleScreenIncomingSmsCall,
    );
    _smsNotificationIntentHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'onSmsNotificationIntentReceived',
      handler: _handleNativeCall,
    );
    _smsRoleChangedHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'onSmsRoleChanged',
      handler: _handleNativeCall,
    );
    _smsSendStatusHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'onSmsSendStatus',
      handler: _handleNativeCall,
    );
    _smsSyncUpdatedHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'onSmsSyncUpdated',
      handler: _handleNativeCall,
    );
    _smsComposeIntentHandlerId ??= NativeChannelRouter.registerHandler(
      method: 'onSmsComposeIntentReceived',
      handler: _handleNativeCall,
    );

    unawaited(_refreshCapabilityState());
    unawaited(_consumePendingSmsNotificationIntent());
    unawaited(_drainPendingSmsEvents());
  }

  static Future<void> _runUrlExtractorUpgradeSweepIfNeeded() async {
    final existing = _urlExtractorUpgradeSweepFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = () async {
      await _storage.initialize();
      await _detectionRepository.initialize();
      final completed =
          await _detectionRepository.getSetting(_urlExtractorUpgradeSweepKey);
      if (completed == 'done') {
        return;
      }

      try {
        await _rescanRecentMessagesForWrappedLinks();
      } catch (error) {
        debugPrint('[SmsService] URL extractor upgrade sweep failed: $error');
      } finally {
        await _detectionRepository.setSetting(
          key: _urlExtractorUpgradeSweepKey,
          value: 'done',
        );
      }
    }();

    _urlExtractorUpgradeSweepFuture = future;
    try {
      await future;
    } finally {
      if (identical(_urlExtractorUpgradeSweepFuture, future)) {
        _urlExtractorUpgradeSweepFuture = null;
      }
    }
  }

  static Future<void> _warmUpDetectionIfNeeded() async {
    final inFlight = _screeningWarmUpFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      try {
        await _pipelineService.initialize();
        await _screeningService.warmUp();
      } catch (error) {
        debugPrint('[SmsService] Detection warm-up skipped: $error');
      }
    }();

    _screeningWarmUpFuture = future;
    try {
      await future;
    } finally {
      if (identical(_screeningWarmUpFuture, future)) {
        _screeningWarmUpFuture = null;
      }
    }
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});

    switch (call.method) {
      case 'onIncomingSmsQueued':
        await _handleIncomingSmsQueued(args);
        break;
      case 'onSmsNotificationIntentReceived':
        await _dispatchSmsNotificationIntent(args);
        break;
      case 'onSmsRoleChanged':
        await _handleRoleChanged(args);
        break;
      case 'onSmsSendStatus':
        await _handleSmsSendStatus(args);
        break;
      case 'onSmsSyncUpdated':
        await _handleSmsSyncUpdated(args);
        break;
      case 'onSmsComposeIntentReceived':
        _dispatchSmsComposeIntent(args);
        break;
      default:
        debugPrint('[SmsService] Unknown native SMS method: ${call.method}');
    }
  }

  static Future<Map<String, dynamic>> _handleScreenIncomingSmsCall(
    MethodCall call,
  ) async {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final message = ScreenedMessageModel.fromMap(args);
    final result = await _screeningService.screenMessage(message);
    return result.toMap();
  }

  static Future<void> _handleIncomingSmsQueued(
    Map<String, dynamic> args,
  ) async {
    final eventId = args['eventId']?.toString() ?? '';
    if (!_registerEvent(eventId)) {
      return;
    }

    final sender = args['sender']?.toString() ?? 'Unknown';
    final senderDisplay = args['senderDisplay']?.toString() ?? '';
    final body = args['body']?.toString() ?? '';
    final simSlot = (args['simSlot'] as num?)?.toInt() ?? 0;
    final timestampMs = (args['timestamp'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final providerId = (args['providerId'] as num?)?.toInt();
    final providerThreadId = args['threadId']?.toString();
    final limitedMode = args['limitedMode'] == true;
    final messageKey = args['messageKey']?.toString() ?? eventId;

    if (body.trim().isEmpty) {
      return;
    }

    final ScreenedMessageModel screenedMessage = ScreenedMessageModel(
      source: limitedMode ? 'sms_limited' : 'sms',
      sender: sender,
      peer: sender,
      body: body,
      timestampMs: timestampMs,
      messageKey: messageKey,
      providerId: providerId,
      providerThreadId: providerThreadId,
      simSlot: simSlot,
      subscriptionId: (args['subscriptionId'] as num?)?.toInt(),
    );
    final SmishingQuickVerdict quickVerdict =
        await _pipelineService.quickScan(screenedMessage);

    if (quickVerdict.status == SafetyStatus.scanning) {
      await _storage.saveMessage(
        SmsMessage(
          sender: sender,
          body: body,
          time: DateTime.fromMillisecondsSinceEpoch(timestampMs),
          simSlot: simSlot,
          providerId: providerId,
          providerThreadId: providerThreadId,
          messageKey: messageKey,
          detectionDecision: 'scanning',
          detectionReasons: const <String>[
            'Scanning suspicious link in the background.',
          ],
          detectionSource: 'tiered_worker_pipeline',
          pipelineStage: 'queue_wait',
          safetyStatus: SafetyStatus.scanning,
        ),
      );
      _pipelineService.enqueue(
        message: screenedMessage,
        priority: SmishingQueuePriority.high,
        onResult: (DetectionResultModel result) async {
          await _applyDetectionOutcome(
            result: result,
            sender: sender,
            body: body,
            timestampMs: timestampMs,
            simSlot: simSlot,
            providerId: providerId,
            providerThreadId: providerThreadId,
            limitedMode: limitedMode,
          );
        },
      );
      if (senderDisplay.isNotEmpty && senderDisplay != sender) {
        await _storage.updateThreadSenderDisplay(sender, senderDisplay);
      }
      await primeInboxThreads(force: true);
      unawaited(scheduleInboxMaintenance(force: true));
      return;
    }

    final DetectionResultModel decision = quickVerdict.result ??
        await _resolveScreeningResult(
          args: args,
          sender: sender,
          body: body,
          timestampMs: timestampMs,
          messageKey: messageKey,
          providerId: providerId,
          providerThreadId: providerThreadId,
          simSlot: simSlot,
          limitedMode: limitedMode,
        );

    if (messageKey.isNotEmpty) {
      await _detectionRepository.bindProviderIdentity(
        messageKey: messageKey,
        providerId: providerId,
        providerThreadId: providerThreadId,
      );
    }
    await _applyDetectionOutcome(
      result: decision,
      sender: sender,
      body: body,
      timestampMs: timestampMs,
      simSlot: simSlot,
      providerId: providerId,
      providerThreadId: providerThreadId,
      limitedMode: limitedMode,
    );

    if (senderDisplay.isNotEmpty && senderDisplay != sender) {
      await _storage.updateThreadSenderDisplay(sender, senderDisplay);
    }

    if (_routingService.shouldRequestRescan(decision)) {
      unawaited(_rescanPendingFallbackMessages());
    }

    await primeInboxThreads(force: true);
    unawaited(scheduleInboxMaintenance(force: true));
  }

  static Future<void> _applyDetectionOutcome({
    required DetectionResultModel result,
    required String sender,
    required String body,
    required int timestampMs,
    required int simSlot,
    required int? providerId,
    required String? providerThreadId,
    required bool limitedMode,
  }) async {
    final SmsMessage message = SmsMessage(
      sender: sender,
      body: body,
      time: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      isSuspicious: result.isSuspicious,
      simSlot: simSlot,
      riskScore: result.riskScore,
      riskLevel: result.riskLevel,
      detectionReasons: result.explanations,
      modelScore: result.modelScore,
      heuristicScore: result.heuristicScore,
      detectionSource: result.detectionSource,
      pipelineStage: result.pipelineStage,
      providerId: providerId,
      providerThreadId: providerThreadId,
      messageKey: result.messageKey,
      detectionDecision: result.decision,
      extractedUrls: result.extractedUrls,
      primaryUrl: result.primaryUrl,
      primaryDomain: result.primaryDomain,
      needsRescan: result.needsRescan,
      safetyStatus:
          result.shouldQuarantine ? SafetyStatus.malicious : SafetyStatus.safe,
    );

    if (_routingService.shouldQuarantine(result)) {
      if (providerId != null && providerId > 0) {
        try {
          await _channel.invokeMethod<bool>('deleteProviderSms', {
            'providerId': providerId,
          });
        } catch (error) {
          debugPrint('[SmsService] deleteProviderSms error: $error');
        }
      }

      await _storage.removeVisibleProviderMessage(
        peer: sender,
        providerId: providerId ?? -1,
      );
      await _storage.saveToQuarantine(message);
      if (!_smsExperienceActive) {
        await NotificationService.showSuspiciousNotification(sender: sender);
      }
      return;
    }

    if (providerId != null && providerId > 0 && !limitedMode) {
      await syncThread(
        address: sender,
        threadId: providerThreadId,
        force: true,
      );
      return;
    }

    await _storage.saveMessage(message);
    if (!_smsExperienceActive) {
      await NotificationService.showSafeNotification(
        sender: sender,
        body: body,
        timestampMs: timestampMs,
      );
    }
  }

  static Future<void> _handleRoleChanged(Map<String, dynamic> args) async {
    capabilityState.value = SmsCapabilityState.fromMap(args);
    if (capabilityState.value.isDefault) {
      await primeInboxThreads(force: true);
      unawaited(scheduleInboxMaintenance(force: true));
    }
  }

  static Future<void> _handleSmsSendStatus(Map<String, dynamic> args) async {
    final eventId = args['eventId']?.toString() ?? '';
    if (!_registerEvent(eventId)) {
      return;
    }

    final address = args['address']?.toString() ?? '';
    if (address.isNotEmpty) {
      await primeSmsThread(address: address, force: true);
    }
    await primeInboxThreads(force: true);
  }

  static Future<void> _handleSmsSyncUpdated(Map<String, dynamic> args) async {
    final reason = args['reason']?.toString() ?? '';
    if (reason == 'mms') {
      await primeInboxThreads(force: true);
      unawaited(scheduleInboxMaintenance(force: true));
      return;
    }

    final address = args['address']?.toString() ?? '';
    final threadId = args['threadId']?.toString();
    if (address.isNotEmpty) {
      await primeSmsThread(address: address, threadId: threadId, force: true);
    }
    await primeInboxThreads(force: true);
  }

  static Future<DetectionResultModel> _resolveScreeningResult({
    required Map<String, dynamic> args,
    required String sender,
    required String body,
    required int timestampMs,
    required String messageKey,
    required int? providerId,
    required String? providerThreadId,
    required int simSlot,
    required bool limitedMode,
  }) async {
    final dynamic rawScreening = args['screeningResult'];
    if (rawScreening is Map) {
      final result = DetectionResultModel.fromMap(
        Map<String, dynamic>.from(rawScreening),
      );
      await _detectionRepository.saveScreeningResult(
        result: result,
        message: ScreenedMessageModel(
          source: limitedMode ? 'sms_limited' : 'sms',
          sender: sender,
          peer: sender,
          body: body,
          timestampMs: timestampMs,
          messageKey: messageKey,
          providerId: providerId,
          providerThreadId: providerThreadId,
          simSlot: simSlot,
          subscriptionId: (args['subscriptionId'] as num?)?.toInt(),
        ),
      );
      return result;
    }

    return _screeningService.screenMessage(
      ScreenedMessageModel(
        source: limitedMode ? 'sms_limited' : 'sms',
        sender: sender,
        peer: sender,
        body: body,
        timestampMs: timestampMs,
        messageKey: messageKey,
        providerId: providerId,
        providerThreadId: providerThreadId,
        simSlot: simSlot,
        subscriptionId: (args['subscriptionId'] as num?)?.toInt(),
      ),
    );
  }

  static Future<void> _rescanPendingFallbackMessages() async {
    final pending =
        await _detectionRepository.listPendingRescanMessages(limit: 12);
    if (pending.isEmpty) {
      return;
    }

    for (final ScreenedMessageModel item in pending) {
      final DetectionResultModel rescored =
          await _screeningService.screenMessage(
        item,
        forceRescore: true,
      );
      if (!_routingService.shouldQuarantine(rescored)) {
        continue;
      }

      if (item.providerId != null && item.providerId! > 0) {
        await deleteProviderMessage(item.providerId!);
        await _storage.removeVisibleProviderMessage(
          peer: item.sender,
          providerId: item.providerId!,
        );
      }

      await _storage.saveToQuarantine(
        SmsMessage(
          sender: item.sender,
          body: item.body,
          time: DateTime.fromMillisecondsSinceEpoch(item.timestampMs),
          isSuspicious: rescored.isSuspicious,
          simSlot: item.simSlot ?? 0,
          riskScore: rescored.riskScore,
          riskLevel: rescored.riskLevel,
          detectionReasons: rescored.explanations,
          modelScore: rescored.modelScore,
          heuristicScore: rescored.heuristicScore,
          detectionSource: rescored.detectionSource,
          pipelineStage: rescored.pipelineStage,
          providerId: item.providerId,
          providerThreadId: item.providerThreadId,
          messageKey: rescored.messageKey,
          detectionDecision: rescored.decision,
          extractedUrls: rescored.extractedUrls,
          primaryUrl: rescored.primaryUrl,
          primaryDomain: rescored.primaryDomain,
          needsRescan: false,
        ),
      );
    }
  }

  static Future<void> _consumePendingSmsNotificationIntent() async {
    try {
      final raw =
          await _channel.invokeMethod<dynamic>('consumePendingSmsIntent');
      if (raw == null) return;
      await _dispatchSmsNotificationIntent(
        Map<String, dynamic>.from(raw as Map<dynamic, dynamic>),
      );
    } catch (error) {
      debugPrint('[SmsService] consumePendingSmsIntent error: $error');
    }
  }

  static Future<void> _dispatchSmsNotificationIntent(
    Map<String, dynamic> args,
  ) async {
    final sender = args['sender']?.toString() ?? '';
    final body = args['body']?.toString() ?? '';
    final timestampMs = (args['timestamp'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final notificationKey = args['notificationKey']?.toString() ?? '';

    if (sender.isEmpty) {
      return;
    }

    final handler = _onSmsNotificationTap;
    if (handler == null) {
      _pendingSmsNotificationIntent = args;
      return;
    }

    handler(
      sender: sender,
      body: body,
      timestampMs: timestampMs,
    );

    if (notificationKey.isNotEmpty) {
      try {
        await _channel.invokeMethod('markSmsIntentHandled', {
          'notificationKey': notificationKey,
        });
      } catch (error) {
        debugPrint('[SmsService] markSmsIntentHandled error: $error');
      }
    }
  }

  static void _dispatchSmsComposeIntent(Map<String, dynamic> args) {
    final phone = args['phone']?.toString() ?? '';
    if (phone.isEmpty) {
      return;
    }

    final handler = _onSmsComposeIntentTap;
    if (handler == null) {
      _pendingSmsComposeIntent = args;
      return;
    }

    handler(
      phone: phone,
      body: args['body']?.toString(),
    );
  }

  static Future<void> _drainPendingSmsEvents() async {
    final inFlight = _pendingEventDrainFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      try {
        final raw = await _channel.invokeMethod<List<dynamic>>(
          'consumePendingSmsEvents',
        );
        if (raw == null || raw.isEmpty) return;
        for (final item in raw) {
          final data = Map<String, dynamic>.from(item as Map);
          final eventType = data['eventType']?.toString() ?? '';
          switch (eventType) {
            case 'incomingSms':
              await _handleIncomingSmsQueued(data);
              break;
            case 'roleChanged':
              await _handleRoleChanged(data);
              break;
            case 'sendStatus':
              await _handleSmsSendStatus(data);
              break;
            case 'syncUpdated':
              await _handleSmsSyncUpdated(data);
              break;
            case 'composeIntent':
              _dispatchSmsComposeIntent(data);
              break;
          }
        }
      } catch (error) {
        debugPrint('[SmsService] consumePendingSmsEvents error: $error');
      }
    }();

    _pendingEventDrainFuture = future;
    try {
      await future;
    } finally {
      if (identical(_pendingEventDrainFuture, future)) {
        _pendingEventDrainFuture = null;
      }
    }
  }

  static bool _registerEvent(String eventId) {
    if (eventId.trim().isEmpty) return true;
    if (_handledEventIds.contains(eventId)) {
      return false;
    }
    _handledEventIds.add(eventId);
    while (_handledEventIds.length > 512) {
      _handledEventIds.remove(_handledEventIds.first);
    }
    return true;
  }

  static Future<SmsCapabilityState> _refreshCapabilityState() async {
    try {
      final raw = await _channel.invokeMethod<dynamic>('getSmsCapabilityState');
      final next = SmsCapabilityState.fromMap(
        Map<String, dynamic>.from(raw as Map<dynamic, dynamic>? ?? const {}),
      );
      capabilityState.value = next;
      return next;
    } catch (error) {
      debugPrint('[SmsService] getSmsCapabilityState error: $error');
      return capabilityState.value;
    }
  }

  static Future<Map<String, dynamic>> _syncThreadsProjection({
    required bool forceFullHistory,
    int threadLimit = 160,
  }) async {
    if (!capabilityState.value.readSmsGranted) {
      return const <String, dynamic>{
        'threads': <Map<String, dynamic>>[],
        'changedThreadIds': <String>[],
        'latestTimestampMs': 0,
        'latestProviderId': 0,
        'threadCount': 0,
      };
    }
    final cursor = await _storage.readSyncCursor();
    dynamic raw;
    try {
      raw = await _channel.invokeMethod<dynamic>('syncSmsNow', {
        'fullHistory': forceFullHistory,
        'sinceTimestampMs': forceFullHistory ? 0 : cursor.latestTimestampMs,
        'sinceProviderId': forceFullHistory ? 0 : cursor.latestProviderId,
        'threadLimit': threadLimit,
      });
    } catch (error) {
      debugPrint('[SmsService] syncSmsNow error: $error');
      return const <String, dynamic>{
        'threads': <Map<String, dynamic>>[],
        'changedThreadIds': <String>[],
        'latestTimestampMs': 0,
        'latestProviderId': 0,
        'threadCount': 0,
      };
    }

    final payload = Map<String, dynamic>.from(
      raw as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{},
    );
    final threadsRaw = payload['threads'] as List<dynamic>?;
    final threads = threadsRaw == null
        ? const <Map<String, dynamic>>[]
        : threadsRaw
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(growable: false);
    await _storage.syncVisibleThreads(threads);
    await _storage.writeSyncCursor(
      latestTimestampMs: (payload['latestTimestampMs'] as num?)?.toInt(),
      latestProviderId: (payload['latestProviderId'] as num?)?.toInt(),
    );
    return <String, dynamic>{
      ...payload,
      'threads': threads,
      'changedThreadIds':
          (payload['changedThreadIds'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => item.toString())
              .where((item) => item.trim().isNotEmpty)
              .toList(growable: false),
    };
  }

  static Future<void> primeInboxThreads({bool force = false}) async {
    final inFlight = _primeInboxFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      await _refreshCapabilityState();
      await _storage.initialize();
      final cursor = await _storage.readSyncCursor();
      if (!force &&
          cursor.lastPrimeAtMs > 0 &&
          DateTime.now().millisecondsSinceEpoch - cursor.lastPrimeAtMs <
              _threadPrimeCooldown.inMilliseconds) {
        return;
      }
      await _syncThreadsProjection(
        forceFullHistory: false,
        threadLimit: force ? 220 : 120,
      );
      await _storage.writeSyncCursor(
        lastPrimeAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }();

    _primeInboxFuture = future;
    try {
      await future;
    } finally {
      if (identical(_primeInboxFuture, future)) {
        _primeInboxFuture = null;
      }
    }
  }

  static Future<void> scheduleInboxMaintenance({
    bool force = false,
    Duration delay = _maintenanceDelay,
  }) async {
    _maintenanceTimer?.cancel();
    _maintenanceTimer = Timer(delay, () {
      unawaited(_runInboxMaintenance(force: force));
    });
  }

  static Future<void> _runInboxMaintenance({bool force = false}) async {
    final inFlight = _maintenanceFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      await _refreshCapabilityState();
      await _drainPendingSmsEvents();
      await _rescanPendingFallbackMessages();
      final payload = await _syncThreadsProjection(
        forceFullHistory: force,
        threadLimit: force ? 220 : 160,
      );
      final threads =
          (payload['threads'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList(growable: false);
      final changedThreadIds =
          (payload['changedThreadIds'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => item.toString())
              .where((item) => item.trim().isNotEmpty)
              .toSet()
              .toList(growable: false);
      for (final threadId in changedThreadIds) {
        final thread = threads.firstWhere(
          (item) => item['threadId']?.toString() == threadId,
          orElse: () => const <String, dynamic>{},
        );
        final sender = thread['sender']?.toString() ?? '';
        if (sender.isEmpty) {
          continue;
        }
        await primeSmsThread(
          address: sender,
          threadId: thread['providerThreadId']?.toString(),
          force: true,
        );
      }
      await _storage.writeSyncCursor(
        lastMaintenanceAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    }();

    _maintenanceFuture = future;
    try {
      await future;
    } finally {
      if (identical(_maintenanceFuture, future)) {
        _maintenanceFuture = null;
      }
    }
  }

  static Future<void> refreshInbox({bool forceFullHistory = false}) async {
    final inFlight = _refreshFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future = () async {
      await primeInboxThreads(force: true);
      await _runInboxMaintenance(force: forceFullHistory);
    }();

    _refreshFuture = future;
    try {
      await future;
    } finally {
      if (identical(_refreshFuture, future)) {
        _refreshFuture = null;
      }
    }
  }

  static Future<void> _rescanRecentMessagesForWrappedLinks() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cutoffMs = nowMs - _urlExtractorUpgradeLookback.inMilliseconds;
    final visibleMessages = await _storage.listAllVisibleMessages();

    final candidates = visibleMessages.where((Map<String, dynamic> message) {
      final bool isOutgoing =
          message['isOutgoing'] == true || message['sender'] == 'Me';
      if (isOutgoing) {
        return false;
      }

      final timestampMs = (message['timestampMs'] as num?)?.toInt() ?? 0;
      if (timestampMs < cutoffMs) {
        return false;
      }

      final extractedUrls =
          (message['extractedUrls'] as List<dynamic>? ?? const <dynamic>[])
              .map((dynamic item) => item.toString())
              .where((String item) => item.trim().isNotEmpty)
              .toList(growable: false);
      if (extractedUrls.isNotEmpty) {
        return false;
      }

      final detectionDecision = message['detectionDecision']?.toString() ?? '';
      final detectionSource = message['detectionSource']?.toString() ?? '';
      final bool needsUpgradeSweep = detectionDecision.isEmpty ||
          detectionDecision == DetectionDecision.noUrlAllow ||
          detectionSource == 'sms_no_url_allow';
      if (!needsUpgradeSweep) {
        return false;
      }

      final body =
          message['body']?.toString() ?? message['text']?.toString() ?? '';
      if (body.trim().isEmpty) {
        return false;
      }

      return _urlExtractionService.extractUrls(body).isNotEmpty;
    }).toList(growable: true)
      ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
        final aTimestamp = (a['timestampMs'] as num?)?.toInt() ?? 0;
        final bTimestamp = (b['timestampMs'] as num?)?.toInt() ?? 0;
        return bTimestamp.compareTo(aTimestamp);
      });

    if (candidates.length > _maxUrlExtractorUpgradeCandidates) {
      candidates.removeRange(
        _maxUrlExtractorUpgradeCandidates,
        candidates.length,
      );
    }

    if (candidates.isEmpty) {
      debugPrint('[SmsService] URL extractor upgrade sweep: no candidates');
      return;
    }

    var movedToQuarantine = 0;
    var refreshedVisible = 0;
    var errors = 0;

    for (final Map<String, dynamic> message in candidates) {
      try {
        final sender = message['sender']?.toString() ?? '';
        final body =
            message['body']?.toString() ?? message['text']?.toString() ?? '';
        final timestampMs = (message['timestampMs'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch;
        final rescored = await _screenStoredSmsEntry(
          sender: sender,
          body: body,
          timestampMs: timestampMs,
          messageKey: _storedMessageKeyForMap(
            message,
            prefix: 'sms_upgrade_rescan',
          ),
          providerId: (message['providerId'] as num?)?.toInt(),
          providerThreadId: message['providerThreadId']?.toString(),
          simSlot: (message['simSlot'] as num?)?.toInt(),
        );

        if (_routingService.shouldQuarantine(rescored)) {
          await _storage.removeVisibleMessage(
            peer: sender,
            providerId: (message['providerId'] as num?)?.toInt(),
            messageId: message['messageId']?.toString(),
          );
          await _storage.saveToQuarantine(
            _smsMessageFromVisibleMap(message, rescored),
          );
          movedToQuarantine++;
        } else {
          await _storage.upsertVisibleMessageMap(
            _visibleMessageMapWithDetection(message, rescored),
          );
          refreshedVisible++;
        }
      } catch (error) {
        errors++;
        debugPrint(
            '[SmsService] URL extractor upgrade sweep item failed: $error');
      }
    }

    debugPrint(
      '[SmsService] URL extractor upgrade sweep complete '
      'candidates=${candidates.length} '
      'movedToQuarantine=$movedToQuarantine '
      'refreshedVisible=$refreshedVisible '
      'errors=$errors',
    );
  }

  static Future<SmsRescanSummary>
      rescanStoredMessagesWithCurrentPipeline() async {
    await _storage.initialize();
    final stopwatch = Stopwatch()..start();

    int rescannedVisible = 0;
    int rescannedQuarantine = 0;
    int movedToQuarantine = 0;
    int restoredToInbox = 0;
    int keptVisible = 0;
    int keptQuarantined = 0;
    int errors = 0;

    final visibleMessages = await _storage.listAllVisibleMessages();
    final quarantineMessages = await _storage.listAllQuarantineMessages();

    for (int index = 0; index < visibleMessages.length; index++) {
      final message = visibleMessages[index];
      if (message['isOutgoing'] == true) {
        continue;
      }
      final body = message['body']?.toString().trim() ?? '';
      final sender = message['sender']?.toString().trim() ?? '';
      if (body.isEmpty || sender.isEmpty) {
        continue;
      }

      try {
        rescannedVisible++;
        final rescored = await _screenStoredSmsEntry(
          sender: sender,
          body: body,
          timestampMs: (message['timestampMs'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          messageKey: _storedMessageKeyForMap(message, prefix: 'rescan'),
          providerId: (message['providerId'] as num?)?.toInt(),
          providerThreadId: message['providerThreadId']?.toString(),
          simSlot: (message['simSlot'] as num?)?.toInt(),
        );

        if (_routingService.shouldQuarantine(rescored)) {
          final providerId = (message['providerId'] as num?)?.toInt();
          if (providerId != null && providerId > 0) {
            await deleteProviderMessage(providerId);
          }
          await _storage.removeVisibleMessage(
            peer: message['peer']?.toString() ?? sender,
            providerId: providerId,
            messageId: message['messageId']?.toString(),
          );
          await _storage.saveToQuarantine(
            _smsMessageFromVisibleMap(
              message,
              rescored,
            ),
          );
          movedToQuarantine++;
        } else {
          await _storage.upsertVisibleMessageMap(
            _visibleMessageMapWithDetection(
              message,
              rescored,
            ),
          );
          keptVisible++;
        }
      } catch (error) {
        errors++;
        debugPrint('[SmsService] manual visible SMS rescan error: $error');
      }

      if (index % 8 == 7) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    for (int index = 0; index < quarantineMessages.length; index++) {
      final message = quarantineMessages[index];
      final body = message['message']?.toString().trim() ?? '';
      final sender = message['sender']?.toString().trim() ?? '';
      if (body.isEmpty || sender.isEmpty) {
        continue;
      }

      try {
        rescannedQuarantine++;
        final rescored = await _screenStoredSmsEntry(
          sender: sender,
          body: body,
          timestampMs: (message['timestampMs'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
          messageKey: _storedMessageKeyForMap(message, prefix: 'rescan_q'),
          providerId: (message['providerId'] as num?)?.toInt(),
          providerThreadId: message['providerThreadId']?.toString(),
          simSlot: (message['simSlot'] as num?)?.toInt(),
        );

        if (_routingService.shouldQuarantine(rescored)) {
          await _storage.saveToQuarantine(
            _smsMessageFromQuarantineMap(
              message,
              rescored,
            ),
          );
          keptQuarantined++;
        } else {
          await _storage.upsertVisibleMessageMap(
            _restoredVisibleMessageMap(
              message,
              rescored,
            ),
          );
          final quarantineId = message['id']?.toString();
          if (quarantineId != null && quarantineId.trim().isNotEmpty) {
            await _storage.deleteQuarantineMessage(quarantineId);
          }
          restoredToInbox++;
        }
      } catch (error) {
        errors++;
        debugPrint('[SmsService] manual quarantine SMS rescan error: $error');
      }

      if (index % 8 == 7) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    stopwatch.stop();
    await primeInboxThreads(force: true);
    unawaited(scheduleInboxMaintenance(force: true));

    return SmsRescanSummary(
      rescannedVisible: rescannedVisible,
      rescannedQuarantine: rescannedQuarantine,
      movedToQuarantine: movedToQuarantine,
      restoredToInbox: restoredToInbox,
      keptVisible: keptVisible,
      keptQuarantined: keptQuarantined,
      errors: errors,
      elapsed: stopwatch.elapsed,
    );
  }

  static Future<void> primeSmsThread({
    required String address,
    String? threadId,
    bool force = false,
  }) async {
    final key = '${address.trim()}|${threadId ?? ''}';
    final inFlight = _threadPrimeFutures[key];
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final future =
        syncThread(address: address, threadId: threadId, force: force);
    _threadPrimeFutures[key] = future;
    try {
      await future;
    } finally {
      if (identical(_threadPrimeFutures[key], future)) {
        _threadPrimeFutures.remove(key);
      }
    }
  }

  static Future<void> syncThread({
    required String address,
    String? threadId,
    bool force = false,
  }) async {
    if (address.trim().isEmpty) return;
    await _refreshCapabilityState();
    if (!capabilityState.value.readSmsGranted) {
      return;
    }
    if (!force && !_smsExperienceActive) {
      return;
    }

    final providerThreadId =
        threadId ?? _storage.cachedProviderThreadIdForPeer(address);
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('getSmsMessages', {
        'threadId': providerThreadId,
        'address': address,
        'limit': force ? 200 : 120,
      });
      final messages = raw == null
          ? const <Map<String, dynamic>>[]
          : raw
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList(growable: false);
      final providerIds = messages
          .map((item) => (item['providerId'] as num?)?.toInt())
          .whereType<int>()
          .toSet()
          .toList(growable: false);
      final overlays = await _detectionRepository
          .getScreeningResultsForProviderIds(providerIds);
      final enrichedMessages = messages.map((message) {
        final providerId = (message['providerId'] as num?)?.toInt();
        final overlay = providerId == null ? null : overlays[providerId];
        if (overlay == null) {
          return message;
        }
        return <String, dynamic>{
          ...message,
          ...overlay.toSmsMetadataMap(),
        };
      }).toList(growable: false);
      await _storage.syncVisibleMessages(
        peer: address,
        nativeMessages: enrichedMessages,
      );
    } catch (error) {
      debugPrint('[SmsService] getSmsMessages error: $error');
    }
  }

  static Future<void> syncRecentDeviceInbox() async {
    await primeInboxThreads(force: true);
    await _runInboxMaintenance(force: true);
  }

  static Future<bool> requestPermissions() async {
    final statuses = await [
      Permission.sms,
      Permission.phone,
      Permission.notification,
    ].request();
    return statuses.values.every((status) => status.isGranted);
  }

  static Future<SmsCapabilityState> getCapabilityState() async {
    return _refreshCapabilityState();
  }

  static Future<bool> isDefaultSmsApp() async {
    final state = await _refreshCapabilityState();
    return state.isDefault;
  }

  static Future<void> requestDefaultSmsApp() async {
    try {
      await _channel.invokeMethod('requestDefaultSmsApp');
    } catch (error) {
      debugPrint('[SmsService] requestDefaultSmsApp error: $error');
    }
  }

  static Future<void> openDefaultSmsSettings() async {
    try {
      await _channel.invokeMethod('openDefaultSmsSettings');
    } catch (error) {
      debugPrint('[SmsService] openDefaultSmsSettings error: $error');
    }
  }

  static Future<void> openDialer(String phone) async {
    try {
      await _channel.invokeMethod('openDialer', {
        'phone': phone,
      });
    } catch (error) {
      debugPrint('[SmsService] openDialer error: $error');
    }
  }

  static Future<void> openAddContact({
    required String phone,
    String? name,
  }) async {
    try {
      await _channel.invokeMethod('openAddContact', {
        'phone': phone,
        'name': name ?? '',
      });
    } catch (error) {
      debugPrint('[SmsService] openAddContact error: $error');
    }
  }

  static Future<void> sendSMS({
    required String phone,
    required String message,
    int simSlot = 0,
  }) async {
    final capability = await _refreshCapabilityState();
    if (!capability.canUseSmsFeatures) {
      throw Exception(
        'Set Smishing Shield PH as the default SMS app to send SMS reliably.',
      );
    }

    final permission = await Permission.sms.status;
    if (!permission.isGranted) {
      final granted = await Permission.sms.request();
      if (!granted.isGranted) {
        throw Exception('SMS permission denied');
      }
    }

    try {
      await _channel.invokeMethod('sendSms', {
        'address': phone,
        'body': message,
        'simSlot': simSlot,
      });
      await primeSmsThread(address: phone, force: true);
      await primeInboxThreads(force: true);
      unawaited(scheduleInboxMaintenance(force: true));
    } on PlatformException catch (error) {
      debugPrint('[SmsService] sendSms error: ${error.message}');
      rethrow;
    }
  }

  static Future<List<Map<String, dynamic>>> getSimSlots() async {
    try {
      final raw = await _channel.invokeMethod<List>('getSimSlots');
      if (raw == null) return [];
      return raw.map((item) => Map<String, dynamic>.from(item as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> deleteProviderMessage(int providerId) async {
    if (providerId <= 0) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('deleteProviderSms', {
        'providerId': providerId,
      });
    } catch (error) {
      debugPrint('[SmsService] deleteProviderSms error: $error');
    }
  }

  static Future<DetectionResultModel> _screenStoredSmsEntry({
    required String sender,
    required String body,
    required int timestampMs,
    required String messageKey,
    int? providerId,
    String? providerThreadId,
    int? simSlot,
  }) async {
    final ScreenedMessageModel message = ScreenedMessageModel(
      source: 'sms',
      sender: sender,
      peer: sender,
      body: body,
      timestampMs: timestampMs,
      messageKey: messageKey,
      providerId: providerId,
      providerThreadId: providerThreadId,
      simSlot: simSlot,
      subscriptionId: null,
    );
    final SmishingQuickVerdict quickVerdict =
        await _pipelineService.quickScan(message);
    if (quickVerdict.result != null) {
      return quickVerdict.result!;
    }
    return _pipelineService.deepScan(message);
  }

  static String _storedMessageKeyForMap(
    Map<String, dynamic> map, {
    required String prefix,
  }) {
    final existing = map['messageKey']?.toString().trim();
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final providerId = (map['providerId'] as num?)?.toInt();
    final timestampMs = (map['timestampMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final sender = map['sender']?.toString() ??
        map['peer']?.toString() ??
        'unknown_sender';
    final body = map['body']?.toString() ?? map['message']?.toString() ?? '';
    return '${prefix}_${providerId ?? timestampMs}_${sender.hashCode}_${body.hashCode}';
  }

  static Map<String, dynamic> _visibleMessageMapWithDetection(
    Map<String, dynamic> original,
    DetectionResultModel rescored,
  ) {
    return <String, dynamic>{
      ...original,
      ...rescored.toSmsMetadataMap(),
      'riskScore': rescored.riskScore,
      'riskLevel': rescored.riskLevel,
      'messageKey': rescored.messageKey,
      'body':
          original['body']?.toString() ?? original['text']?.toString() ?? '',
      'text':
          original['text']?.toString() ?? original['body']?.toString() ?? '',
      'needsRescan': rescored.needsRescan,
      'safetyStatus': rescored.shouldQuarantine ? 'malicious' : 'safe',
    };
  }

  static Map<String, dynamic> _restoredVisibleMessageMap(
    Map<String, dynamic> quarantineEntry,
    DetectionResultModel rescored,
  ) {
    final timestampMs = (quarantineEntry['timestampMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    final sender = quarantineEntry['sender']?.toString() ?? '';
    return <String, dynamic>{
      'messageId': quarantineEntry['messageId']?.toString(),
      'providerId': (quarantineEntry['providerId'] as num?)?.toInt(),
      'providerThreadId': quarantineEntry['providerThreadId']?.toString(),
      'threadId': quarantineEntry['threadId']?.toString(),
      'sender': sender,
      'receiver': quarantineEntry['receiver']?.toString(),
      'peer': sender,
      'body': quarantineEntry['message']?.toString() ?? '',
      'text': quarantineEntry['message']?.toString() ?? '',
      'time': quarantineEntry['time']?.toString() ??
          DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String(),
      'timestamp': quarantineEntry['timestamp']?.toString() ??
          DateTime.fromMillisecondsSinceEpoch(timestampMs).toIso8601String(),
      'timestampMs': timestampMs,
      'isOutgoing': false,
      'status': 'received',
      'source': quarantineEntry['source']?.toString() ?? 'sms_rescan_restore',
      ...rescored.toSmsMetadataMap(),
      'riskScore': rescored.riskScore,
      'riskLevel': rescored.riskLevel,
      'messageKey': rescored.messageKey,
      'needsRescan': rescored.needsRescan,
      'safetyStatus': rescored.shouldQuarantine ? 'malicious' : 'safe',
    };
  }

  static SmsMessage _smsMessageFromVisibleMap(
    Map<String, dynamic> message,
    DetectionResultModel rescored,
  ) {
    final timestampMs = (message['timestampMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    return SmsMessage(
      sender: message['sender']?.toString() ?? '',
      body: message['body']?.toString() ?? message['text']?.toString() ?? '',
      time: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      receiver: message['receiver']?.toString(),
      isSuspicious: rescored.isSuspicious,
      simSlot: (message['simSlot'] as num?)?.toInt() ?? 0,
      isOutgoing: message['isOutgoing'] == true,
      status: message['status']?.toString(),
      source: message['source']?.toString(),
      riskScore: rescored.riskScore,
      riskLevel: rescored.riskLevel,
      detectionReasons: rescored.explanations,
      modelScore: rescored.modelScore,
      heuristicScore: rescored.heuristicScore,
      detectionSource: rescored.detectionSource,
      pipelineStage: rescored.pipelineStage,
      providerId: (message['providerId'] as num?)?.toInt(),
      providerThreadId: message['providerThreadId']?.toString(),
      messageKey: rescored.messageKey,
      detectionDecision: rescored.decision,
      extractedUrls: rescored.extractedUrls,
      primaryUrl: rescored.primaryUrl,
      primaryDomain: rescored.primaryDomain,
      needsRescan: rescored.needsRescan,
      safetyStatus: rescored.shouldQuarantine
          ? SafetyStatus.malicious
          : SafetyStatus.safe,
    );
  }

  static SmsMessage _smsMessageFromQuarantineMap(
    Map<String, dynamic> message,
    DetectionResultModel rescored,
  ) {
    final timestampMs = (message['timestampMs'] as num?)?.toInt() ??
        DateTime.now().millisecondsSinceEpoch;
    return SmsMessage(
      sender: message['sender']?.toString() ?? '',
      body: message['message']?.toString() ?? '',
      time: DateTime.fromMillisecondsSinceEpoch(timestampMs),
      isSuspicious: rescored.isSuspicious,
      simSlot: (message['simSlot'] as num?)?.toInt() ?? 0,
      riskScore: rescored.riskScore,
      riskLevel: rescored.riskLevel,
      detectionReasons: rescored.explanations,
      modelScore: rescored.modelScore,
      heuristicScore: rescored.heuristicScore,
      detectionSource: rescored.detectionSource,
      pipelineStage: rescored.pipelineStage,
      providerId: (message['providerId'] as num?)?.toInt(),
      providerThreadId: message['providerThreadId']?.toString(),
      messageKey: rescored.messageKey,
      detectionDecision: rescored.decision,
      extractedUrls: rescored.extractedUrls,
      primaryUrl: rescored.primaryUrl,
      primaryDomain: rescored.primaryDomain,
      needsRescan: rescored.needsRescan,
      safetyStatus: rescored.shouldQuarantine
          ? SafetyStatus.malicious
          : SafetyStatus.safe,
    );
  }
}
