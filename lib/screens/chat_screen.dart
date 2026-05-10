import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ui_message_model.dart';
import '../models/safety_status.dart';
import '../services/chat/chat_notification_service.dart';
import '../services/chat/contact_chat_service.dart';
import '../services/call/call_notification_service.dart';
import '../services/media/cloudinary_service.dart';
import '../services/media/gif_search_service.dart';
import '../services/contacts/device_contact_sync_service.dart';
import '../services/feedback/feedback_database_service.dart';
import '../services/feedback/feedback_service.dart';
import '../services/chat/fcm_chat_service.dart';
import '../services/media/media_service.dart';
import '../services/chat/online_chat_service.dart';
import '../services/sms/sms_service.dart';
import '../services/sms/sms_storage_service.dart';
import '../smishing_detection_pipeline/pipeline_service.dart';
import '../services/auth/user_profile_service.dart';
import '../widgets/feedback_upload_consent_dialog.dart';
import '../widgets/message_bubble.dart';
import '../widgets/user_avatar.dart';
import 'call_screen.dart';
import 'quarantine_screen.dart';

enum _ChatMenuAction {
  muteNotifications,
  unmuteNotifications,
  blockUser,
  unblockUser,
  markUnread,
  markRead,
}

class ChatScreen extends StatefulWidget {
  final String contactName;
  final String phone;
  final String chatType;
  final String? receiverId;
  final bool openedFromActiveCall;
  final String? initialDraftText;

  const ChatScreen({
    super.key,
    required this.contactName,
    required this.phone,
    required this.chatType,
    this.receiverId,
    this.openedFromActiveCall = false,
    this.initialDraftText,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController messageController = TextEditingController();
  final ScrollController _messageScrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  final MediaService mediaService = MediaService();
  final OnlineChatService onlineChatService = OnlineChatService();
  final ContactChatService contactChatService = ContactChatService();
  final FcmChatService _fcmChatService = FcmChatService();
  final CloudinaryService _cloudinaryService = CloudinaryService();
  final GifSearchService _gifSearchService = GifSearchService();
  final SmsStorageService _smsStorage = SmsStorageService();
  final FeedbackService _feedbackService = FeedbackService();
  final UserProfileService _userProfileService = UserProfileService();
  final DomainAllowlist _trustedDomainService = DomainAllowlist();
  final UrlExtractor _urlExtractionService = UrlExtractor();
  final Map<String, Future<_LinkMeta>> _linkPreviewCache =
      <String, Future<_LinkMeta>>{};

  static const int _maxFileSizeBytes = 25 * 1024 * 1024;
  static const Duration _externalLinkCountdown = Duration(seconds: 4);
  static const Duration _typingDebounce = Duration(seconds: 2);

  Timer? _typingTimer;
  Timer? _connectionBannerTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _isUploading = false;
  bool _isSendingMessage = false;
  bool? _hasInternetConnection;
  bool _showConnectedBanner = false;
  bool _connectivityInitialized = false;
  bool _hadConnectivityOutage = false;
  double _uploadProgress = 0.0;
  bool _initialBottomSnapDone = false;
  bool _autoScrollEnabled = true;
  int _scrollRequestToken = 0;
  bool _notificationsMuted = false;
  bool _blockedByMe = false;
  bool _blockedByThem = false;
  bool _manuallyUnread = false;
  List<Map<String, dynamic>> _smsSimSlots = <Map<String, dynamic>>[];
  int _selectedSmsSimSlot = 0;
  String? _smsResolvedContactName;
  bool _smsCanSendFromApp = false;

  // Edit state
  String? _editingMessageId;
  int _editingCount = 0;

  late Stream<QuerySnapshot<Map<String, dynamic>>> _onlineMessagesStream;
  late Stream<List<Map<String, dynamic>>> _smsMessagesStream;

  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get otherUserId => widget.receiverId ?? widget.phone;
  String? _lastRenderedMessageKey;
  String? _cachedOnlineDocsKey;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _cachedOnlineDocs =
      const <QueryDocumentSnapshot<Map<String, dynamic>>>[];

  String get _smsPeerPhone {
    final compact = widget.phone.trim().replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (compact.startsWith('+63') && compact.length > 3) {
      return '0${compact.substring(3)}';
    }
    if (compact.startsWith('63') && compact.length > 2) {
      return '0${compact.substring(2)}';
    }
    return compact;
  }

  bool _looksLikeSmsPhoneLabel(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return true;
    final normalized = DeviceContactSyncService.normalizePhone(trimmed);
    if (normalized.isEmpty) return false;
    final compact = trimmed.replaceAll(RegExp(r'[^0-9+]'), '');
    return compact == trimmed || normalized == trimmed;
  }

  bool get _shouldResolveSmsHeaderNameFromContacts {
    if (widget.chatType != 'sms') return false;
    final currentLabel = widget.contactName.trim();
    if (currentLabel.isEmpty) return true;
    return _looksLikeSmsPhoneLabel(currentLabel) ||
        currentLabel.toLowerCase() == 'unknown';
  }

  String get _displayName {
    if (widget.chatType == 'sms') {
      final resolved = _smsResolvedContactName?.trim() ?? '';
      if (resolved.isNotEmpty) {
        return resolved;
      }
    }
    final raw = widget.contactName.trim();
    if (raw.isEmpty) return 'Unknown';
    if (!raw.contains('@')) return raw;
    final localPart = raw.split('@').first.trim();
    return localPart.isNotEmpty ? localPart : raw;
  }

  bool get _isConversationBlocked => _blockedByMe || _blockedByThem;

  String get _blockedBannerText {
    if (_blockedByMe) {
      return 'You blocked this user. Unblock them from the menu to message or call again.';
    }
    if (_blockedByThem) {
      return 'This user is not accepting messages or calls from you right now.';
    }
    return '';
  }

  Future<void> _refreshChatRelationship() async {
    if (widget.chatType != 'online' || otherUserId.isEmpty) return;
    final relationship =
        await onlineChatService.getChatRelationship(otherUserId);
    if (!mounted) return;
    setState(() {
      _notificationsMuted = relationship['mutedNotifications'] == true;
      _blockedByMe = relationship['blockedByMe'] == true;
      _blockedByThem = relationship['blockedByThem'] == true;
      _manuallyUnread = relationship['manualUnread'] == true;
    });
  }

  Color _presenceColor(String mode, bool isOnline) {
    switch (OnlineChatService.normalizePresenceMode(mode)) {
      case 'dnd':
        return Colors.redAccent;
      case 'idle':
        return Colors.amber;
      case 'invisible':
        return Colors.grey;
      case 'online':
      default:
        return isOnline ? const Color(0xFF25D366) : Colors.grey;
    }
  }

  String _presenceLabel(String mode, bool isOnline) {
    switch (OnlineChatService.normalizePresenceMode(mode)) {
      case 'dnd':
        return 'Do Not Disturb';
      case 'idle':
        return 'Idle';
      case 'invisible':
        return '';
      case 'online':
      default:
        return isOnline ? 'Online' : '';
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.initialDraftText?.trim().isNotEmpty == true) {
      messageController.text = widget.initialDraftText!.trimRight();
      messageController.selection = TextSelection.collapsed(
        offset: messageController.text.length,
      );
    }
    _messageFocusNode.addListener(_handleComposerFocusChanged);
    if (widget.chatType == 'sms') {
      _smsMessagesStream = _smsStorage.watchMessages(_smsPeerPhone);
      SmsService.enterSmsExperience();
      _smsStorage.markAsRead(_smsPeerPhone);
      unawaited(SmsService.primeSmsThread(address: _smsPeerPhone, force: true));
      unawaited(SmsService.scheduleInboxMaintenance());
      unawaited(_loadSmsSimSlots());
      unawaited(_refreshSmsContactDisplayName());
      unawaited(_loadSmsCapabilityState());
    } else {
      _onlineMessagesStream = onlineChatService.getMessages(otherUserId);
      _startConnectivityMonitor();
      unawaited(_refreshChatRelationship());
      ChatNotificationService()
          .setActiveChat(onlineChatService.getChatId(otherUserId));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onlineChatService.markMessagesAsRead(otherUserId);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isConversationBlocked) {
        return;
      }
      FocusScope.of(context).requestFocus(_messageFocusNode);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.chatType == 'sms') {
      SmsService.leaveSmsExperience();
    }
    messageController.dispose();
    _messageFocusNode.dispose();
    _messageScrollController.dispose();
    _typingTimer?.cancel();
    _connectionBannerTimer?.cancel();
    _connectivitySubscription?.cancel();
    if (widget.chatType == 'online') {
      ChatNotificationService().setActiveChat(null);
      unawaited(
        onlineChatService.setTyping(otherUserId: otherUserId, isTyping: false),
      );
    }
    super.dispose();
  }

  void _startConnectivityMonitor() {
    _connectivitySubscription =
        Connectivity().onConnectivityChanged.listen(_handleConnectivityChange);
    unawaited(_checkInitialConnectivity());
  }

  Future<void> _checkInitialConnectivity() async {
    try {
      final results = await Connectivity().checkConnectivity();
      _setInitialConnectivityState(results);
    } catch (error) {
      debugPrint('[ChatScreen] Connectivity check failed: $error');
    }
  }

  void _setInitialConnectivityState(List<ConnectivityResult> results) {
    if (!mounted || widget.chatType != 'online') return;
    final hasConnection = results.any(
      (result) => result != ConnectivityResult.none,
    );
    setState(() {
      _hasInternetConnection = hasConnection;
      _showConnectedBanner = false;
      _connectivityInitialized = true;
    });
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    if (!mounted || widget.chatType != 'online') return;

    final hasConnection = results.any(
      (result) => result != ConnectivityResult.none,
    );
    final previous = _hasInternetConnection;

    if (!_connectivityInitialized) {
      setState(() {
        _hasInternetConnection = hasConnection;
        _showConnectedBanner = false;
        _connectivityInitialized = true;
      });
      return;
    }

    if (previous == hasConnection) {
      return;
    }

    _connectionBannerTimer?.cancel();
    setState(() {
      _hasInternetConnection = hasConnection;
      if (!hasConnection && previous == true) {
        _hadConnectivityOutage = true;
        _showConnectedBanner = false;
      } else {
        _showConnectedBanner = hasConnection && _hadConnectivityOutage;
      }
    });

    if (!hasConnection) return;

    _connectionBannerTimer = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted || _hasInternetConnection != true) return;
      setState(() {
        _showConnectedBanner = false;
        _hadConnectivityOutage = false;
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.chatType == 'sms') {
      if (state == AppLifecycleState.resumed) {
        unawaited(_refreshSmsContactDisplayName());
        unawaited(_loadSmsCapabilityState());
        unawaited(
            SmsService.primeSmsThread(address: _smsPeerPhone, force: true));
        unawaited(SmsService.scheduleInboxMaintenance());
      }
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _typingTimer?.cancel();
      unawaited(
        onlineChatService.setTyping(otherUserId: otherUserId, isTyping: false),
      );
    }
  }

  Future<void> _loadSmsCapabilityState() async {
    final capability = await SmsService.getCapabilityState();
    if (!mounted) return;
    setState(() {
      _smsCanSendFromApp = capability.canUseSmsFeatures;
    });
  }

  Future<void> _refreshSmsContactDisplayName() async {
    if (widget.chatType != 'sms') return;
    if (!_shouldResolveSmsHeaderNameFromContacts) {
      return;
    }

    final permission = await Permission.contacts.status;
    if (!permission.isGranted) return;

    final targetKey = DeviceContactSyncService.normalizePhone(_smsPeerPhone);
    if (targetKey.isEmpty) return;

    final contacts = await FlutterContacts.getContacts(withProperties: true);
    String? resolvedName;
    for (final contact in contacts) {
      for (final phone in contact.phones) {
        final phoneKey = DeviceContactSyncService.normalizePhone(phone.number);
        if (phoneKey == targetKey) {
          final name = contact.displayName.trim();
          if (name.isNotEmpty) {
            resolvedName = name;
            break;
          }
        }
      }
      if (resolvedName != null) {
        break;
      }
    }

    if (!mounted ||
        resolvedName == null ||
        resolvedName == _smsResolvedContactName) {
      return;
    }
    setState(() {
      _smsResolvedContactName = resolvedName;
    });
  }

  Future<void> _loadSmsSimSlots() async {
    try {
      final slots = await SmsService.getSimSlots();
      if (!mounted) return;
      setState(() {
        _smsSimSlots = slots.isEmpty
            ? <Map<String, dynamic>>[
                {'slotIndex': 0, 'displayName': 'SIM1'},
              ]
            : slots;
        final available = _smsSimSlots
            .map((slot) => (slot['slotIndex'] as num?)?.toInt() ?? 0)
            .toSet();
        if (!available.contains(_selectedSmsSimSlot)) {
          _selectedSmsSimSlot =
              (_smsSimSlots.first['slotIndex'] as num?)?.toInt() ?? 0;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _smsSimSlots = <Map<String, dynamic>>[
          {'slotIndex': 0, 'displayName': 'SIM1'},
        ];
        _selectedSmsSimSlot = 0;
      });
    }
  }

  String get _selectedSmsSimLabel {
    for (final slot in _smsSimSlots) {
      final slotIndex = (slot['slotIndex'] as num?)?.toInt() ?? 0;
      if (slotIndex == _selectedSmsSimSlot) {
        final label = slot['displayName']?.toString().trim() ?? '';
        if (label.isNotEmpty) return label;
      }
    }
    return 'SIM${_selectedSmsSimSlot + 1}';
  }

  Future<void> _showSmsSimPicker() async {
    if (_smsSimSlots.isEmpty) {
      await _loadSmsSimSlots();
    }
    if (!mounted) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171717),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Choose SIM for SMS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ..._smsSimSlots.map((slot) {
                final slotIndex = (slot['slotIndex'] as num?)?.toInt() ?? 0;
                final label =
                    slot['displayName']?.toString().trim().isNotEmpty == true
                        ? slot['displayName'].toString().trim()
                        : 'SIM${slotIndex + 1}';
                final selected = slotIndex == _selectedSmsSimSlot;
                return ListTile(
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    color: selected ? const Color(0xFF25D366) : Colors.white54,
                  ),
                  title: Text(
                    label,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () {
                    setState(() => _selectedSmsSimSlot = slotIndex);
                    Navigator.pop(context);
                  },
                );
              }),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  // â”€â”€ Permissions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<bool> requestCallPermissions({required bool isVideo}) async {
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) micStatus = await Permission.microphone.request();
    if (micStatus.isPermanentlyDenied) {
      if (!mounted) return false;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Permission Required'),
          content: const Text(
              'Microphone permission was permanently denied. Please enable it in App Settings.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () {
                  Navigator.pop(context);
                  openAppSettings();
                },
                child: const Text('Open Settings')),
          ],
        ),
      );
      return false;
    }
    if (!micStatus.isGranted) return false;
    if (isVideo) {
      var camStatus = await Permission.camera.status;
      if (!camStatus.isGranted) camStatus = await Permission.camera.request();
      if (camStatus.isPermanentlyDenied) {
        if (mounted) openAppSettings();
        return false;
      }
      return camStatus.isGranted;
    }
    return true;
  }

  // â”€â”€ Open URL â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> _openUrl(String url) async {
    final normalizedUrl = _normalizeUrl(url);
    final uri = Uri.parse(normalizedUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open file.')),
      );
    }
  }

  String _normalizeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    return 'https://$trimmed';
  }

  Future<void> _copyText(String text, {required String successText}) async {
    if (text.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(successText)),
    );
  }

  Future<void> _openLegitLink(String url) async {
    final normalizedUrl = _normalizeUrl(url);
    if (await _trustedDomainService.isUrlTrusted(normalizedUrl)) {
      await _openUrl(normalizedUrl);
      return;
    }
    await _confirmOpenExternalUrl(normalizedUrl);
  }

  Future<void> _confirmOpenExternalUrl(String url) async {
    final shouldOpen = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _RiskyLinkDialog(
            defangedUrl: _urlExtractionService.defangUrl(url),
            countdown: _externalLinkCountdown,
          ),
        ) ??
        false;

    if (!shouldOpen || !mounted) return;
    await _openUrl(url);
  }

  Future<void> _resumeActiveCall(Map<String, dynamic> activeCall) async {
    final callId = activeCall['callId']?.toString() ?? '';
    final receiverId = activeCall['receiverId']?.toString() ?? otherUserId;
    final contactName =
        activeCall['contactName']?.toString().trim().isNotEmpty == true
            ? activeCall['contactName'].toString()
            : _displayName;
    final isVideo = activeCall['isVideo'] == true;
    final isCaller = activeCall['isCaller'] == true;

    if (callId.isEmpty || !mounted) return;

    CallNotificationService.setCallMinimized(false);

    if (widget.openedFromActiveCall && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          contactName: contactName,
          receiverId: receiverId,
          isVideo: isVideo,
          isCaller: isCaller,
          incomingCallId: callId,
          resumeActiveCall: true,
        ),
      ),
    );
  }

  void _showCallPermissionMessage({required bool isVideo}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isVideo
              ? 'Camera and microphone permissions are required.'
              : 'Microphone permission is required.',
        ),
      ),
    );
  }

  void _openOutgoingCall({required bool isVideo}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CallScreen(
          contactName: _displayName,
          receiverId: otherUserId,
          isVideo: isVideo,
          isCaller: true,
        ),
      ),
    );
  }

  List<Widget> _buildChatActions(bool isSms) {
    if (isSms) return <Widget>[];

    return <Widget>[
      ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: CallNotificationService.activeCallState,
        builder: (context, activeCall, _) {
          final isMatchingActiveCall = activeCall != null &&
              widget.chatType == 'online' &&
              widget.receiverId != null &&
              activeCall['receiverId']?.toString() == widget.receiverId &&
              (activeCall['callId']?.toString().isNotEmpty ?? false);

          if (isMatchingActiveCall) {
            final isVideo = activeCall['isVideo'] == true;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonal(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: () => _resumeActiveCall(activeCall),
                child: Text(isVideo ? 'Return to call' : 'Return to call'),
              ),
            );
          }

          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_isConversationBlocked) ...[
                IconButton(
                  icon: const Icon(Icons.call, color: Colors.white),
                  onPressed: () async {
                    final granted =
                        await requestCallPermissions(isVideo: false);

                    if (!mounted) return;

                    if (!granted) {
                      _showCallPermissionMessage(isVideo: false);
                      return;
                    }

                    _openOutgoingCall(isVideo: false);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.videocam, color: Colors.white),
                  onPressed: () async {
                    final granted = await requestCallPermissions(isVideo: true);

                    if (!mounted) return;

                    if (!granted) {
                      _showCallPermissionMessage(isVideo: true);
                      return;
                    }

                    _openOutgoingCall(isVideo: true);
                  },
                ),
              ],
              PopupMenuButton<_ChatMenuAction>(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                color: const Color(0xFF122133),
                iconColor: Colors.white,
                onSelected: _handleChatMenuAction,
                itemBuilder: (context) => <PopupMenuEntry<_ChatMenuAction>>[
                  PopupMenuItem<_ChatMenuAction>(
                    value: _notificationsMuted
                        ? _ChatMenuAction.unmuteNotifications
                        : _ChatMenuAction.muteNotifications,
                    child: Text(
                      _notificationsMuted
                          ? 'Unmute notifications'
                          : 'Mute notifications',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem<_ChatMenuAction>(
                    value: _blockedByMe
                        ? _ChatMenuAction.unblockUser
                        : _ChatMenuAction.blockUser,
                    child: Text(
                      _blockedByMe ? 'Unblock user' : 'Block user',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  PopupMenuItem<_ChatMenuAction>(
                    value: _manuallyUnread
                        ? _ChatMenuAction.markRead
                        : _ChatMenuAction.markUnread,
                    child: Text(
                      _manuallyUnread ? 'Mark as read' : 'Mark as unread',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ];
  }

  Future<void> _handleChatMenuAction(_ChatMenuAction action) async {
    try {
      switch (action) {
        case _ChatMenuAction.muteNotifications:
          await onlineChatService.setConversationMuted(
            otherUserId: otherUserId,
            muted: true,
          );
          if (!mounted) return;
          setState(() => _notificationsMuted = true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Notifications muted for $_displayName')),
          );
          return;
        case _ChatMenuAction.unmuteNotifications:
          await onlineChatService.setConversationMuted(
            otherUserId: otherUserId,
            muted: false,
          );
          if (!mounted) return;
          setState(() => _notificationsMuted = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Notifications unmuted for $_displayName')),
          );
          return;
        case _ChatMenuAction.blockUser:
          final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: Text('Block $_displayName?'),
                  content: const Text(
                    'Messages, calls, and notifications from this user will be blocked until you unblock them.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Block'),
                    ),
                  ],
                ),
              ) ??
              false;
          if (!confirmed) return;
          await onlineChatService.setConversationBlocked(
            otherUserId: otherUserId,
            blocked: true,
            otherName: _displayName,
          );
          if (!mounted) return;
          setState(() => _blockedByMe = true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$_displayName blocked')),
          );
          return;
        case _ChatMenuAction.unblockUser:
          await onlineChatService.setConversationBlocked(
            otherUserId: otherUserId,
            blocked: false,
            otherName: _displayName,
          );
          if (!mounted) return;
          setState(() => _blockedByMe = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$_displayName unblocked')),
          );
          return;
        case _ChatMenuAction.markUnread:
          await onlineChatService.markConversationUnread(otherUserId);
          if (!mounted) return;
          setState(() => _manuallyUnread = true);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Marked $_displayName as unread')),
          );
          return;
        case _ChatMenuAction.markRead:
          await onlineChatService.markMessagesAsRead(otherUserId);
          if (!mounted) return;
          setState(() => _manuallyUnread = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Marked $_displayName as read')),
          );
          return;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action failed: $e')),
      );
    } finally {
      unawaited(_refreshChatRelationship());
    }
  }

  Future<void> _openImagePreview(
    String imagePath, {
    required bool isNetwork,
    required bool isSuspicious,
  }) async {
    if (isSuspicious) {
      await _confirmOpenExternalUrl(imagePath);
      return;
    }

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: isNetwork
                  ? Image.network(imagePath, fit: BoxFit.contain)
                  : Image.file(File(imagePath), fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  void _scheduleScrollToLatest(String messageKey, {required int messageCount}) {
    if (_lastRenderedMessageKey == messageKey) {
      return;
    }

    _lastRenderedMessageKey = messageKey;

    final nearBottom = _isNearBottom(threshold: 220);
    final shouldFollowLatest =
        !_initialBottomSnapDone || (_autoScrollEnabled && nearBottom);

    if (!shouldFollowLatest) {
      return;
    }

    final requestToken = ++_scrollRequestToken;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || requestToken != _scrollRequestToken) return;
      _scrollToBottom(
        immediate: !_initialBottomSnapDone,
        retries: 0,
        requestToken: requestToken,
      );
    });
  }

  bool get _usesReverseThreadLayout => widget.chatType == 'online';

  bool _isNearBottom({double threshold = 120}) {
    if (!_messageScrollController.hasClients) return true;
    final position = _messageScrollController.position;
    if (_usesReverseThreadLayout) {
      return position.pixels <= threshold;
    }
    return (position.maxScrollExtent - position.pixels) <= threshold;
  }

  bool _handleMessageScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;

    final isNearBottom = _usesReverseThreadLayout
        ? notification.metrics.pixels <= 96
        : (notification.metrics.maxScrollExtent -
                notification.metrics.pixels) <=
            96;

    final isUserDriven = notification is UserScrollNotification ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null) ||
        (notification is OverscrollNotification &&
            notification.dragDetails != null);

    if (isUserDriven) {
      _autoScrollEnabled = isNearBottom;
      _scrollRequestToken++;
    }

    return false;
  }

  void _scrollToBottom({
    required bool immediate,
    int retries = 0,
    int? requestToken,
  }) {
    if (!_messageScrollController.hasClients) return;
    if (_initialBottomSnapDone && !_autoScrollEnabled) return;
    if (requestToken != null && requestToken != _scrollRequestToken) return;

    final position = _messageScrollController.position;
    final target = _usesReverseThreadLayout
        ? position.minScrollExtent
        : position.maxScrollExtent;
    if (!immediate && (target - position.pixels).abs() < 2) {
      return;
    }

    if (immediate) {
      _messageScrollController.jumpTo(target);
      _initialBottomSnapDone = true;
    } else {
      _messageScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
      _initialBottomSnapDone = true;
    }
    if (_isNearBottom(threshold: 180)) {
      _autoScrollEnabled = true;
    }
  }

  bool detectSuspiciousText(String text) {
    final lower = text.toLowerCase();
    return lower.contains('click') ||
        lower.contains('verify') ||
        lower.contains('bank') ||
        lower.contains('urgent') ||
        lower.contains('link') ||
        lower.contains('claim') ||
        lower.contains('prize') ||
        lower.contains('otp') ||
        lower.contains('password') ||
        lower.contains('login') ||
        lower.contains('limited time') ||
        lower.contains('gcash') ||
        lower.contains('maya') ||
        lower.contains('bdo') ||
        lower.contains('bpi') ||
        lower.contains('nanalo') ||
        lower.contains('ayuda');
  }

  String formatTime(DateTime time) {
    final hour = time.hour == 0
        ? 12
        : time.hour > 12
            ? time.hour - 12
            : time.hour;
    final minute = time.minute.toString().padLeft(2, '0');
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $suffix';
  }

  DateTime extractFirestoreTime(dynamic timestamp) {
    if (timestamp is Timestamp) return timestamp.toDate();
    if (timestamp is DateTime) return timestamp;
    if (timestamp is int) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    }
    if (timestamp is num) {
      return DateTime.fromMillisecondsSinceEpoch(timestamp.toInt());
    }
    if (timestamp is String) {
      final parsedInt = int.tryParse(timestamp);
      if (parsedInt != null) {
        return DateTime.fromMillisecondsSinceEpoch(parsedInt);
      }
      final parsedDate = DateTime.tryParse(timestamp);
      if (parsedDate != null) {
        return parsedDate;
      }
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  DateTime _extractBestMessageTime(Map<String, dynamic> data) {
    final primary = extractFirestoreTime(data['timestamp']);
    if (primary.millisecondsSinceEpoch > 0) {
      return primary;
    }
    final edited = extractFirestoreTime(data['editedAt']);
    if (edited.millisecondsSinceEpoch > 0) {
      return edited;
    }
    final updated = extractFirestoreTime(data['updatedAt']);
    if (updated.millisecondsSinceEpoch > 0) {
      return updated;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  String _documentChangeTypeKey(DocumentChangeType type) {
    switch (type) {
      case DocumentChangeType.added:
        return 'a';
      case DocumentChangeType.modified:
        return 'm';
      case DocumentChangeType.removed:
        return 'r';
    }
  }

  String _buildOnlineDocsCacheKey(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final docs = snapshot.docs;
    final rawFirstId = docs.isNotEmpty ? docs.first.id : '';
    final rawLastId = docs.isNotEmpty ? docs.last.id : '';
    final changeSignature = snapshot.docChanges.isEmpty
        ? 'none'
        : snapshot.docChanges.map((change) {
            final data = change.doc.data() ?? const <String, dynamic>{};
            final deletedFor = data['deletedFor'] as List?;
            final deletedForSig = deletedFor?.join(',') ?? '';
            return '${_documentChangeTypeKey(change.type)}:${change.doc.id}:'
                '${_extractBestMessageTime(data).millisecondsSinceEpoch}:'
                '${data['isDeleted'] == true ? 1 : 0}:'
                '${data['isReported'] == true ? 1 : 0}:$deletedForSig';
          }).join('|');
    return '${docs.length}|$rawFirstId|$rawLastId|$changeSignature|'
        '${snapshot.metadata.hasPendingWrites ? 1 : 0}|'
        '${snapshot.metadata.isFromCache ? 1 : 0}';
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _resolveOnlineDocs(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final cacheKey = _buildOnlineDocsCacheKey(snapshot);
    if (_cachedOnlineDocsKey == cacheKey) {
      return _cachedOnlineDocs;
    }

    final docs = snapshot.docs.where((doc) {
      final data = doc.data();
      if (data['isReported'] == true) return false;
      final deletedFor = data['deletedFor'] as List?;
      if (deletedFor != null && deletedFor.contains(currentUserId)) {
        return false;
      }
      return true;
    }).toList()
      ..sort((a, b) {
        final aTs = _extractBestMessageTime(a.data()).millisecondsSinceEpoch;
        final bTs = _extractBestMessageTime(b.data()).millisecondsSinceEpoch;
        return bTs.compareTo(aTs);
      });

    _cachedOnlineDocsKey = cacheKey;
    _cachedOnlineDocs = docs;
    return docs;
  }

  void onTyping() {
    if (widget.chatType != 'online' || !_messageFocusNode.hasFocus) return;
    final hasText = messageController.text.trim().isNotEmpty;
    _typingTimer?.cancel();

    unawaited(
      onlineChatService.setTyping(
        otherUserId: otherUserId,
        isTyping: hasText,
      ),
    );

    if (!hasText) {
      return;
    }

    _typingTimer = Timer(_typingDebounce, () {
      if (!mounted) return;
      unawaited(
        onlineChatService.setTyping(
          otherUserId: otherUserId,
          isTyping: false,
        ),
      );
    });
  }

  void _handleComposerFocusChanged() {
    if (widget.chatType != 'online') {
      return;
    }
    if (!_messageFocusNode.hasFocus) {
      _typingTimer?.cancel();
    }
    unawaited(
      onlineChatService.setTyping(
        otherUserId: otherUserId,
        isTyping: _messageFocusNode.hasFocus &&
            messageController.text.trim().isNotEmpty,
      ),
    );
  }

  String _feedbackStatusLabel(FeedbackUploadStatus status) {
    switch (status) {
      case FeedbackUploadStatus.uploaded:
        return 'Uploaded to Firebase.';
      case FeedbackUploadStatus.queued:
        return 'Queued for Firebase retry.';
      case FeedbackUploadStatus.disabled:
        return 'Feedback upload is off in Settings.';
    }
  }

  // â”€â”€ Send / Edit text message â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> sendMessage() async {
    final text = messageController.text.trim();
    if (text.isEmpty) {
      return; // Removed _isSendingMessage check for fast sending
    }
    if (widget.chatType == 'online' && _isConversationBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_blockedBannerText)),
      );
      return;
    }

    if (_editingMessageId != null) {
      setState(() => _isSendingMessage = true);
      try {
        await onlineChatService.editMessage(
          otherUserId: otherUserId,
          messageId: _editingMessageId!,
          newText: text,
          currentEditCount: _editingCount,
        );
        messageController.clear();
        setState(() {
          _editingMessageId = null;
          _editingCount = 0;
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      } finally {
        if (mounted) {
          setState(() => _isSendingMessage = false);
        }
      }
      return;
    }

    // --- Optimistic UI Updates ---
    messageController.clear();
    _typingTimer?.cancel();
    unawaited(
      onlineChatService.setTyping(otherUserId: otherUserId, isTyping: false),
    );
    _scrollToBottom(immediate: false);

    if (widget.chatType == 'sms') {
      if (!_smsCanSendFromApp) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Set Smishing Shield PH as the default SMS app to send SMS reliably.')));
        return;
      }

      // Fire-and-forget SMS
      unawaited(() async {
        try {
          await SmsService.sendSMS(
            phone: _smsPeerPhone,
            message: text,
            simSlot: _selectedSmsSimSlot,
          );
          await SmsService.primeSmsThread(address: _smsPeerPhone, force: true);
          unawaited(SmsService.scheduleInboxMaintenance(force: true));
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('SMS Send failed: $e')));
          }
        }
      }());
    } else {
      final keyboardGifUrl = _extractKeyboardGifUrl(text);
      if (keyboardGifUrl != null) {
        // Fire-and-forget media link
        unawaited(_sendRemoteMediaUrlToFirestore(
          mediaUrl: keyboardGifUrl,
          type: 'gif',
          fileName: _inferKeyboardGifFileName(keyboardGifUrl),
        ).catchError((e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Failed to send GIF: $e')));
          }
        }));
      } else {
        // Fire-and-forget text
        unawaited(onlineChatService
            .sendMessage(
          receiverId: otherUserId,
          text: text,
          receiverName: _displayName,
        )
            .catchError((Object e) {
          if (!mounted) return;
          final msg = e.toString().contains('not enabled secure messaging')
              ? 'Contact hasn\'t set up secure messaging yet. Ask them to open the app and try again.'
              : e.toString().contains('No logged-in user')
                  ? 'You\'re not signed in. Please restart the app.'
                  : 'Message failed to send. Please try again.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              duration: const Duration(seconds: 4),
            ),
          );
        }));
      }
    }
  }

  // â”€â”€ Camera â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> takePhoto() async {
    final file = await mediaService.takePhoto();
    if (file == null) return;

    final fileSize = await file.length();
    if (fileSize > _maxFileSizeBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo exceeds the 25MB limit.')));
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    try {
      await _sendMediaToFirestore(
        file: file,
        type: 'image',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  // â”€â”€ Send image from gallery â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> sendImage() async {
    final file = await mediaService.pickImageFromGallery();
    if (file == null) return;

    final fileSize = await file.length();
    if (fileSize > _maxFileSizeBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Image exceeds the 25MB limit.')));
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    try {
      if (widget.chatType == 'online') {
        await _sendMediaToFirestore(
          file: file,
          type: 'image',
        );
      } else {
        final result = await _cloudinaryService.uploadFile(
          file,
          onProgress: _updateUploadProgress,
        );
        await _smsStorage.saveOutgoingMessage(
          receiver: _smsPeerPhone,
          body: result.url,
          simSlot: _selectedSmsSimSlot,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  Future<void> sendGif() async {
    if (widget.chatType != 'online') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('GIFs are available for online chat.')),
      );
      return;
    }
    if (_isConversationBlocked) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_blockedBannerText)),
      );
      return;
    }

    final selectedGif = await showModalBottomSheet<GifResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) => _GifPickerSheet(gifSearchService: _gifSearchService),
    );
    if (selectedGif == null) return;

    try {
      await _sendRemoteMediaUrlToFirestore(
        mediaUrl: selectedGif.gifUrl,
        type: 'gif',
        fileName: 'giphy_${selectedGif.id}.gif',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to send GIF: $e')));
    }
  }

  // â”€â”€ Send file â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Future<void> sendFile() async {
    final file = await mediaService.pickAnyFile();
    if (file == null) return;

    final fileSize = await file.length();
    if (fileSize > _maxFileSizeBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('File exceeds the 25MB limit.')));
      return;
    }

    setState(() {
      _isUploading = true;
      _uploadProgress = 0.0;
    });

    try {
      if (widget.chatType == 'online') {
        await _sendMediaToFirestore(
          file: file,
          type: file.path.toLowerCase().endsWith('.gif')
              ? 'gif'
              : _isImageFile(file.path)
                  ? 'image'
                  : 'file',
        );
      } else {
        final result = await _cloudinaryService.uploadFile(
          file,
          onProgress: _updateUploadProgress,
        );
        await _smsStorage.saveOutgoingMessage(
          receiver: _smsPeerPhone,
          body: result.fileName,
          simSlot: _selectedSmsSimSlot,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  // â”€â”€ Save media to Firestore â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  bool _isImageFile(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp') ||
        lower.endsWith('.heic');
  }

  String _formatFileSize(int sizeBytes) {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  void _updateUploadProgress(double progress) {
    if (!mounted) return;
    final normalized = progress.clamp(0.0, 1.0);
    if ((_uploadProgress - normalized).abs() < 0.001) {
      return;
    }
    setState(() => _uploadProgress = normalized);
  }

  Future<void> _sendMediaToFirestore({
    required File file,
    required String type,
  }) async {
    await onlineChatService.assertMessagingAllowed(otherUserId);
    final chatId = onlineChatService.getChatId(otherUserId);
    final senderName = await onlineChatService.getCurrentUserDisplayName();
    final receiverDisplayName = await _userProfileService.fetchDisplayName(
      otherUserId,
      fallback: _displayName,
    );
    final rawName = file.path.split(Platform.pathSeparator).last;
    final activityClientMs = DateTime.now().millisecondsSinceEpoch;
    final clientMessageId =
        FirebaseFirestore.instance.collection('chats').doc().id;
    final uploadResult = await _cloudinaryService.uploadFile(
      file,
      onProgress: _updateUploadProgress,
    );

    final sizeLabel = _formatFileSize(await file.length());
    final messageRef = FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(clientMessageId);
    await messageRef.set({
      'clientMessageId': clientMessageId,
      'senderId': currentUserId,
      'senderName': senderName,
      'receiverId': otherUserId,
      'text': uploadResult.url,
      'fileName': rawName,
      'fileSize': sizeLabel,
      'type': type,
      'isSuspicious': false,
      'isReported': false,
      'isRead': false,
      'isDeleted': false,
      'editCount': 0,
      'timestamp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await onlineChatService.upsertConversationSummaryFromMessage(
      otherUserId: otherUserId,
      messageData: <String, dynamic>{
        'senderId': currentUserId,
        'senderName': senderName,
        'receiverId': otherUserId,
        'text': uploadResult.url,
        'type': type,
        'fileName': rawName,
      },
      lastMessageId: clientMessageId,
      activityClientMs: activityClientMs,
      currentUserDisplayName: senderName,
      otherUserDisplayName: receiverDisplayName,
    );

    await _fcmChatService.notifyIncomingChat(
      receiverId: otherUserId,
      chatId: chatId,
      messageId: messageRef.id,
      senderName: senderName,
      preview: type == 'gif'
          ? 'Sent a GIF'
          : type == 'image'
              ? 'Sent a photo'
              : 'Sent a file',
      type: type,
    );
  }

  Future<void> _sendRemoteMediaUrlToFirestore({
    required String mediaUrl,
    required String type,
    required String fileName,
  }) async {
    await onlineChatService.assertMessagingAllowed(otherUserId);
    final chatId = onlineChatService.getChatId(otherUserId);
    final senderName = await onlineChatService.getCurrentUserDisplayName();
    final receiverDisplayName = await _userProfileService.fetchDisplayName(
      otherUserId,
      fallback: _displayName,
    );
    final activityClientMs = DateTime.now().millisecondsSinceEpoch;
    final clientMessageId =
        FirebaseFirestore.instance.collection('chats').doc().id;
    final messageRef = FirebaseFirestore.instance
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .doc(clientMessageId);

    await messageRef.set({
      'clientMessageId': clientMessageId,
      'senderId': currentUserId,
      'senderName': senderName,
      'receiverId': otherUserId,
      'text': mediaUrl,
      'fileName': fileName,
      'type': type,
      'isSuspicious': false,
      'isReported': false,
      'isRead': false,
      'isDeleted': false,
      'editCount': 0,
      'timestamp': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    await onlineChatService.upsertConversationSummaryFromMessage(
      otherUserId: otherUserId,
      messageData: <String, dynamic>{
        'senderId': currentUserId,
        'senderName': senderName,
        'receiverId': otherUserId,
        'text': mediaUrl,
        'type': type,
        'fileName': fileName,
      },
      lastMessageId: clientMessageId,
      activityClientMs: activityClientMs,
      currentUserDisplayName: senderName,
      otherUserDisplayName: receiverDisplayName,
    );

    await _fcmChatService.notifyIncomingChat(
      receiverId: otherUserId,
      chatId: chatId,
      messageId: messageRef.id,
      senderName: senderName,
      preview: type == 'gif' ? 'Sent a GIF' : 'Sent media',
      type: type,
    );
  }

  String? _extractKeyboardGifUrl(String rawText) {
    if (widget.chatType != 'online') {
      return null;
    }
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    final extractedUrls = _urlExtractionService.extractUrls(trimmed);
    if (extractedUrls.length != 1) {
      return null;
    }
    final rawUrl = extractedUrls.first.trim();
    final normalizedUrl = _normalizeUrl(rawUrl);
    final collapsedText = trimmed.replaceAll(RegExp(r'\s+'), '');
    final collapsedUrl = rawUrl.replaceAll(RegExp(r'\s+'), '');
    final collapsedNormalized = normalizedUrl.replaceAll(RegExp(r'\s+'), '');
    if (collapsedText != collapsedUrl && collapsedText != collapsedNormalized) {
      return null;
    }
    final uri = Uri.tryParse(normalizedUrl);
    if (uri == null || !_looksLikeDirectGifUrl(uri)) {
      return null;
    }
    return normalizedUrl;
  }

  bool _looksLikeDirectGifUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    if (path.endsWith('.gif') || path.endsWith('.gifv')) {
      return true;
    }
    if ((host == 'media.giphy.com' || host.endsWith('.giphy.com')) &&
        (path.contains('/media/') || path.contains('giphy.gif'))) {
      return true;
    }
    return false;
  }

  String _inferKeyboardGifFileName(String url) {
    final uri = Uri.tryParse(url);
    final lastSegment =
        uri != null && uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
    if (lastSegment.trim().isNotEmpty) {
      return lastSegment;
    }
    return 'keyboard.gif';
  }

  // â”€â”€ Show attachment picker â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _showAttachmentPicker() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _attachOption(
                    icon: Icons.camera_alt,
                    label: 'Camera',
                    color: const Color(0xFF075E54),
                    onTap: () {
                      Navigator.pop(context);
                      takePhoto();
                    },
                  ),
                  _attachOption(
                    icon: Icons.photo_library,
                    label: 'Gallery',
                    color: Colors.purple,
                    onTap: () {
                      Navigator.pop(context);
                      sendImage();
                    },
                  ),
                  _attachOption(
                    icon: Icons.gif_box_outlined,
                    label: 'GIF',
                    color: Colors.teal,
                    onTap: () {
                      Navigator.pop(context);
                      sendGif();
                    },
                  ),
                  _attachOption(
                    icon: Icons.insert_drive_file,
                    label: 'File',
                    color: Colors.blue,
                    onTap: () {
                      Navigator.pop(context);
                      sendFile();
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attachOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: color.withValues(alpha: 0.12),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(height: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Future<void> deleteLocalMessage(MessageModel msg) async {
    final String? localMessageId = msg.messageKey?.trim().isNotEmpty == true
        ? 'local_${msg.messageKey!}'
        : null;
    await _smsStorage.removeVisibleMessage(
      peer: _smsPeerPhone,
      providerId: msg.providerId,
      messageId: localMessageId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message deleted for you.')));
  }

  Future<void> reportLocalMessage(MessageModel msg) async {
    try {
      await ensureFeedbackUploadPreference(context);

      final uploadStatus = await _feedbackService.reportSmsMessageAsSmishing(
        peer: _smsPeerPhone,
        message: msg,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Message reported to quarantine. ${_feedbackStatusLabel(uploadStatus)}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to report: $e')));
    }
  }

  Future<void> reportOnlineMessage(Map<String, dynamic> msg) async {
    final messageText = msg['type'] == 'text'
        ? (msg['text'] ?? '')
        : '[${msg['type'] ?? 'message'}]';
    final docPath = msg['docPath'] ?? '';
    try {
      await ensureFeedbackUploadPreference(context);

      final uploadStatus = await onlineChatService.reportMessageToQuarantine(
        sender: _displayName,
        message: messageText,
        source: 'online',
        messageDocPath: docPath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Message reported to quarantine. ${_feedbackStatusLabel(uploadStatus)}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to report: $e')));
    }
  }

  Future<void> reportFalseNegativeLocal(MessageModel msg) async {
    try {
      await ensureFeedbackUploadPreference(context);

      final uploadStatus = await _feedbackService.reportSmsMessageAsSmishing(
        peer: _smsPeerPhone,
        message: msg,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Reported as smishing. ${_feedbackStatusLabel(uploadStatus)}',
        ),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to report: $e')));
    }
  }

  Future<void> reportFalseNegativeOnline(Map<String, dynamic> msg) async {
    final messageText = msg['type'] == 'text'
        ? (msg['text'] ?? '')
        : '[${msg['type'] ?? 'message'}]';
    final docPath = msg['docPath'] ?? '';
    try {
      await ensureFeedbackUploadPreference(context);

      final uploadStatus = await onlineChatService.reportMessageToQuarantine(
        sender: _displayName,
        message: messageText,
        source: 'false_negative_online',
        messageDocPath: docPath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Reported as smishing. ${_feedbackStatusLabel(uploadStatus)}',
        ),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to report: $e')));
    }
  }

  // â”€â”€ Local message options (SMS) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void showLocalMessageOptions(MessageModel msg) {
    final bool scanning = msg.safetyStatus == SafetyStatus.scanning;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Wrap(children: [
          if (!scanning && msg.text.trim().isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy'),
              onTap: () async {
                Navigator.pop(context);
                await _copyText(
                  msg.text,
                  successText: 'Message copied',
                );
              },
            ),
          if (!scanning)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(context);
                unawaited(deleteLocalMessage(msg));
              },
            ),
          if (!scanning)
            ListTile(
              leading:
                  const Icon(Icons.warning_amber_rounded, color: Colors.red),
              title: const Text('Report as Smishing/Spam'),
              onTap: () {
                Navigator.pop(context);
                if (msg.isSuspicious) {
                  reportLocalMessage(msg);
                } else {
                  reportFalseNegativeLocal(msg);
                }
              },
            ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('Cancel'),
            onTap: () => Navigator.pop(context),
          ),
        ]),
      ),
    );
  }

  // â”€â”€ Online message options â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void showOnlineMessageOptions(Map<String, dynamic> msg) {
    final isMe = msg['isMe'] == true;
    final msgId = msg['messageId'] ?? '';
    final msgText = msg['text'] ?? '';
    final isDeleted = msg['isDeleted'] == true;
    final bool flagged = msg['isSuspicious'] == true;
    final safetyStatus =
        SafetyStatus.fromValue(msg['safetyStatus']?.toString());
    final scanning = safetyStatus == SafetyStatus.scanning;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Wrap(children: [
          if (!flagged &&
              !scanning &&
              !isDeleted &&
              msgText.toString().trim().isNotEmpty)
            ListTile(
              leading: const Icon(Icons.forward_outlined),
              title: const Text('Forward'),
              onTap: () {
                Navigator.pop(context);
                unawaited(_showForwardMessageSheet(msg));
              },
            ),
          if (!flagged && !isDeleted && msgText.toString().trim().isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy'),
              onTap: () async {
                Navigator.pop(context);
                await _copyText(
                  msgText.toString(),
                  successText: 'Message copied',
                );
              },
            ),
          if (!isDeleted)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteOnline(msgId, isMe);
              },
            ),
          if (!flagged &&
              !scanning &&
              !isMe &&
              msg['isSuspicious'] != true &&
              !isDeleted)
            ListTile(
              leading:
                  const Icon(Icons.warning_amber_rounded, color: Colors.red),
              title: const Text('Report as Smishing/Spam'),
              onTap: () {
                Navigator.pop(context);
                reportFalseNegativeOnline(msg);
              },
            ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('Cancel'),
            onTap: () => Navigator.pop(context),
          ),
        ]),
      ),
    );
  }

  Future<List<_ForwardRecipient>> _loadForwardRecipients() async {
    final snapshot = await contactChatService.getMyContacts().first;
    final recipients = <_ForwardRecipient>[];
    for (final doc in snapshot.docs) {
      final rawData = doc.data();
      if (rawData is! Map) continue;
      final data = Map<String, dynamic>.from(rawData);
      final uid = (data['uid'] ?? doc.id).toString().trim();
      if (uid.isEmpty || uid == currentUserId || uid == otherUserId) continue;
      final name = (data['name'] ?? data['displayName'] ?? data['email'] ?? uid)
          .toString()
          .trim();
      recipients.add(_ForwardRecipient(
        uid: uid,
        name: name.isEmpty ? uid : name,
        email: data['email']?.toString(),
      ));
    }
    recipients.sort((a, b) => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ));
    return recipients;
  }

  Future<void> _showForwardMessageSheet(Map<String, dynamic> msg) async {
    final selected = <String, _ForwardRecipient>{};
    final recipientsFuture = _loadForwardRecipients();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          return SafeArea(
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.68,
              minChildSize: 0.42,
              maxChildSize: 0.88,
              builder: (context, scrollController) {
                return FutureBuilder<List<_ForwardRecipient>>(
                  future: recipientsFuture,
                  builder: (context, snapshot) {
                    final recipients =
                        snapshot.data ?? const <_ForwardRecipient>[];
                    return Column(
                      children: [
                        Container(
                          width: 40,
                          height: 4,
                          margin: const EdgeInsets.only(top: 10, bottom: 14),
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Forward to',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                              Text(
                                '${selected.length}/5',
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Builder(
                            builder: (context) {
                              if (snapshot.connectionState ==
                                  ConnectionState.waiting) {
                                return const Center(
                                  child: CircularProgressIndicator(
                                    color: Color(0xFF25D366),
                                  ),
                                );
                              }
                              if (snapshot.hasError) {
                                return const Center(
                                  child: Text(
                                    'Could not load contacts.',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                );
                              }
                              if (recipients.isEmpty) {
                                return const Center(
                                  child: Text(
                                    'No other online contacts available.',
                                    style: TextStyle(color: Colors.white70),
                                  ),
                                );
                              }
                              return ListView.builder(
                                controller: scrollController,
                                itemCount: recipients.length,
                                itemBuilder: (context, index) {
                                  final recipient = recipients[index];
                                  final checked =
                                      selected.containsKey(recipient.uid);
                                  final disabled =
                                      !checked && selected.length >= 5;
                                  return CheckboxListTile(
                                    value: checked,
                                    activeColor: const Color(0xFF25D366),
                                    checkColor: Colors.white,
                                    onChanged: disabled
                                        ? null
                                        : (value) {
                                            setSheetState(() {
                                              if (value == true) {
                                                selected[recipient.uid] =
                                                    recipient;
                                              } else {
                                                selected.remove(recipient.uid);
                                              }
                                            });
                                          },
                                    secondary: UserAvatar(
                                      name: recipient.name,
                                      radius: 18,
                                      backgroundColor: const Color(0xFF1A2737),
                                      foregroundColor: Colors.white,
                                    ),
                                    title: Text(
                                      recipient.name,
                                      style:
                                          const TextStyle(color: Colors.white),
                                    ),
                                    subtitle:
                                        recipient.email?.trim().isNotEmpty ==
                                                true
                                            ? Text(
                                                recipient.email!,
                                                style: const TextStyle(
                                                  color: Colors.white54,
                                                ),
                                              )
                                            : null,
                                  );
                                },
                              );
                            },
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                          child: SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: selected.isEmpty
                                  ? null
                                  : () {
                                      final targets = selected.values
                                          .toList(growable: false);
                                      Navigator.pop(sheetContext);
                                      unawaited(_forwardOnlineMessage(
                                        msg: msg,
                                        recipients: targets,
                                      ));
                                    },
                              icon: const Icon(Icons.forward_outlined),
                              label: Text(
                                selected.isEmpty
                                    ? 'Select recipients'
                                    : 'Forward to ${selected.length}',
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _forwardOnlineMessage({
    required Map<String, dynamic> msg,
    required List<_ForwardRecipient> recipients,
  }) async {
    final text = msg['text']?.toString().trim() ?? '';
    if (text.isEmpty || recipients.isEmpty) return;
    final limitedRecipients = recipients.take(5).toList(growable: false);
    final type = msg['type']?.toString() ?? 'text';
    final fileName = msg['fileName']?.toString();

    var sent = 0;
    for (final recipient in limitedRecipients) {
      try {
        await onlineChatService.forwardMessage(
          receiverId: recipient.uid,
          receiverName: recipient.name,
          text: text,
          type: type,
          fileName: fileName,
        );
        sent++;
      } catch (error) {
        debugPrint('[ChatScreen] Forward failed for ${recipient.uid}: $error');
      }
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent == limitedRecipients.length
              ? 'Forwarded to $sent ${sent == 1 ? "person" : "people"}'
              : 'Forwarded to $sent of ${limitedRecipients.length} people',
        ),
      ),
    );
  }

  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _editingCount = 0;
      messageController.clear();
    });
  }

  // â”€â”€ Confirm delete online message â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  void _confirmDeleteOnline(String messageId, bool isMe) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Delete Message?'),
        content: Text(isMe
            ? 'This will delete the message for everyone in this chat.'
            : 'This will remove the message from your view only.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context);
              final messenger = ScaffoldMessenger.of(context);
              try {
                await onlineChatService.deleteMessage(
                  otherUserId: otherUserId,
                  messageId: messageId,
                  isMyMessage: isMe,
                );
              } catch (e) {
                messenger
                    .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  bool _isTrustedRestoreData(Map<String, dynamic> data) {
    return data['detectionDecision']?.toString() == 'allow_trusted' ||
        data['detectionSource']?.toString() == 'trusted_restore' ||
        data['trustedByReceiverId']?.toString() == currentUserId;
  }

  String _formatLastSeen(dynamic timestamp) {
    if (timestamp == null) return 'Last seen recently';
    DateTime dt;
    if (timestamp is DateTime) {
      dt = timestamp;
    } else {
      try {
        dt = (timestamp as dynamic).toDate();
      } catch (_) {
        return 'Last seen recently';
      }
    }
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Last seen just now';
    if (diff.inMinutes < 60) return 'Last seen ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last seen ${diff.inHours}h ago';
    return 'Last seen ${diff.inDays}d ago';
  }

  Color getHeaderColor() => widget.chatType == 'sms'
      ? const Color(0xFF8E5A00)
      : const Color(0xFF075E54);

  Color get _screenBackground => const Color(0xFF0B1622);
  Color get _surfaceColor => const Color(0xFF101C2B);
  Color get _surfaceElevatedColor => const Color(0xFF162334);
  Color get _inputFillColor => const Color(0xFF1A2737);
  Color get _outlineColor => Colors.white10;

  Widget _buildModeBanner({required bool isSms}) {
    final icon = isSms ? Icons.shield_moon_outlined : Icons.lock_outline;
    final title = isSms ? 'SMS protection is active' : 'Online chat is active';
    final subtitle = isSms
        ? (_smsCanSendFromApp
            ? 'This SMS thread is synced from the Android SMS provider. Suspicious SMS may be flagged or moved into quarantine.'
            : 'Limited mode: you can review synced SMS here, but reliable send/receive requires Smishing Shield PH to be the default SMS app.')
        : 'Messages are delivered in real time with anti-smishing protection.';

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _surfaceElevatedColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _outlineColor),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 14,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: (isSms ? const Color(0xFFE28B28) : const Color(0xFF25D366))
                  .withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              icon,
              color: isSms ? const Color(0xFFFFC266) : const Color(0xFF7CE9B6),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionBanner() {
    final bool? connected = _hasInternetConnection;
    if (widget.chatType != 'online' ||
        connected == null ||
        (!connected && !_hadConnectivityOutage) ||
        (connected && !_showConnectedBanner)) {
      return const SizedBox.shrink();
    }

    final Color color =
        connected ? const Color(0xFF1FAE5B) : const Color(0xFFE53935);
    final String text = connected ? 'Connected' : 'No internet connection';

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Container(
        key: ValueKey<String>(text),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 5),
        color: color,
        alignment: Alignment.center,
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildForwardedIndicator({required bool isMe}) {
    return Padding(
      padding: EdgeInsets.only(
        left: isMe ? 0 : 12,
        right: isMe ? 12 : 0,
        bottom: 3,
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forward_outlined,
            size: 13,
            color: Colors.white54,
          ),
          SizedBox(width: 4),
          Text(
            'Forwarded message',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildSuspiciousWarningCard({
    required bool isSuspicious,
    required bool isMe,
    double? riskScore,
    VoidCallback? onDeleteForMe,
    VoidCallback? onViewQuarantine,
    SafetyStatus safetyStatus = SafetyStatus.safe,
  }) {
    final bool showScanning = safetyStatus == SafetyStatus.scanning;
    if (!isSuspicious && !showScanning) return const SizedBox.shrink();
    final String label = showScanning
        ? 'Screening the incoming message before it is shown.'
        : 'Malicious content detected. This message might steal your information.';
    return Container(
      margin: EdgeInsets.only(
          left: isMe ? 60 : 10, right: isMe ? 10 : 60, bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: showScanning ? const Color(0xFF172433) : const Color(0xFF3A1818),
        border: Border.all(
          color: showScanning
              ? const Color(0xFF67AAFF).withValues(alpha: 0.6)
              : const Color(0xFFFF7A7A).withValues(alpha: 0.6),
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                showScanning
                    ? Icons.shield_outlined
                    : Icons.warning_amber_rounded,
                color: showScanning
                    ? const Color(0xFF8BC2FF)
                    : const Color(0xFFFF8A8A),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: showScanning
                        ? const Color(0xFFC9E4FF)
                        : const Color(0xFFFFD0D0),
                  ),
                ),
              ),
            ],
          ),
          if (onDeleteForMe != null && !showScanning) ...[
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onDeleteForMe,
                child: const Text(
                  'Delete it for me',
                  style: TextStyle(color: Color(0xFFFFB6B6)),
                ),
              ),
            ),
          ],
          if (isSuspicious && !showScanning && onViewQuarantine != null) ...[
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onViewQuarantine,
                child: const Text(
                  'View on Quarantine Vault',
                  style: TextStyle(color: Color(0xFFFFC266)),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // â”€â”€ Message content builder â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget buildMessageContent(MessageModel msg) {
    if (msg.type == 'deleted') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 14, color: Colors.grey.shade400),
            const SizedBox(width: 6),
            Text(
              'Message deleted',
              style: TextStyle(
                  color: Colors.grey.shade400,
                  fontStyle: FontStyle.italic,
                  fontSize: 13),
            ),
          ],
        ),
      );
    }

    if (msg.type == 'call_summary') {
      final isVideo = msg.text.toLowerCase().contains('video');

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: _surfaceElevatedColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _outlineColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: const Color(0xFF25D366).withValues(alpha: 0.14),
              child: Icon(
                isVideo ? Icons.videocam : Icons.call,
                size: 16,
                color: const Color(0xFF7CE9B6),
              ),
            ),
            const SizedBox(width: 10),
            Text(
              msg.text,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      );
    }

    final trustedRestore = msg.detectionDecision == 'allow_trusted' ||
        msg.detectionSource == 'trusted_restore';
    final blocked = !trustedRestore &&
        (msg.isSuspicious || msg.safetyStatus == SafetyStatus.malicious);
    if (blocked) {
      return Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF26161A),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFFFF7A7A).withValues(alpha: 0.45),
          ),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.shield_outlined, size: 18, color: Color(0xFFFFB6B6)),
            SizedBox(width: 10),
            Text(
              'Message hidden for safety',
              style: TextStyle(
                color: Color(0xFFFFD0D0),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    if (msg.type == 'image' || msg.type == 'gif') {
      final isUrl = msg.text.startsWith('http');
      return GestureDetector(
        onTap: () async {
          if (msg.isSuspicious) {
            return;
          }
          if (msg.type == 'gif' && isUrl && !msg.isSuspicious) {
            await _openImagePreview(
              msg.text,
              isNetwork: true,
              isSuspicious: false,
            );
            return;
          }

          await _openImagePreview(
            msg.text,
            isNetwork: isUrl,
            isSuspicious: msg.isSuspicious,
          );
        },
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72,
            maxHeight: 260,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: isUrl
                ? Image.network(
                    msg.text,
                    fit: BoxFit.cover,
                    loadingBuilder: (_, child, progress) {
                      if (progress == null) return child;
                      return Container(
                        width: 200,
                        height: 150,
                        color: Colors.grey.shade200,
                        child: const Center(
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      );
                    },
                    errorBuilder: (_, __, ___) => Container(
                      width: 200,
                      height: 100,
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  )
                : Image.file(File(msg.text), fit: BoxFit.cover),
          ),
        ),
      );
    }

    if (msg.type == 'file') {
      final fileUrl = msg.filePath ?? msg.text;
      final isUrl = fileUrl.startsWith('http');
      final displayName = msg.text.isNotEmpty ? msg.text : 'File';
      return GestureDetector(
        onTap:
            isUrl && !msg.isSuspicious ? () => _openLegitLink(fileUrl) : null,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: msg.isMe ? const Color(0xFF153323) : _surfaceElevatedColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _outlineColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file_outlined,
                  color: isUrl ? const Color(0xFF075E54) : Colors.grey),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(displayName,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: isUrl
                                ? const Color(0xFF7CE9B6)
                                : Colors.white)),
                    if (isUrl)
                      const Text('Tap to open',
                          style:
                              TextStyle(fontSize: 11, color: Colors.white54)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (msg.safetyStatus == SafetyStatus.scanning) {
      return Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.72,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF132234),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF4C86BF)),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF8BC2FF),
              ),
            ),
            SizedBox(width: 10),
            Text(
              'Scanning message...',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    final isSafe = !msg.isSuspicious && msg.safetyStatus == SafetyStatus.safe;
    // primaryUrl/extractedUrls are only populated for SMS messages.
    // For online chat messages fall back to scanning the text directly.
    final inlineUrlRegex = RegExp(r'https?://[^\s]+', caseSensitive: false);
    final previewUrl = msg.primaryUrl?.isNotEmpty == true
        ? msg.primaryUrl
        : (msg.extractedUrls.isNotEmpty
            ? msg.extractedUrls.first
            : inlineUrlRegex.firstMatch(msg.text)?.group(0));

    return IgnorePointer(
      ignoring: msg.safetyStatus == SafetyStatus.malicious || msg.isSuspicious,
      child: Column(
        crossAxisAlignment:
            msg.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MessageBubble(
            text: msg.text,
            isMe: msg.isMe,
            onUrlTap: isSafe ? _openLegitLink : null,
          ),
          if (isSafe && previewUrl != null)
            _buildLinkPreview(previewUrl, msg.isMe),
        ],
      ),
    );
  }

  Future<_LinkMeta> _getLinkMeta(String url) =>
      _linkPreviewCache.putIfAbsent(url, () => _fetchLinkMeta(url));

  Future<_LinkMeta> _fetchLinkMeta(String url) async {
    Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return _LinkMeta(domain: url);
    }
    final domain = uri.host.replaceAll('www.', '');
    const timeout = Duration(seconds: 2);

    try {
      // TikTok oEmbed â€” returns real thumbnail_url without JS rendering.
      if (domain.contains('tiktok.com')) {
        final res = await http.get(
          Uri.parse(
              'https://www.tiktok.com/oembed?url=${Uri.encodeComponent(url)}'),
          headers: {'User-Agent': 'Mozilla/5.0'},
        ).timeout(timeout);
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          return _LinkMeta(
            title: data['title']?.toString(),
            description: data['author_name']?.toString(),
            imageUrl: data['thumbnail_url']?.toString(),
            domain: domain,
          );
        }
      }

      // YouTube oEmbed â€” returns real thumbnail_url.
      if (domain.contains('youtube.com') || domain.contains('youtu.be')) {
        final res = await http.get(
          Uri.parse(
              'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json'),
          headers: {'User-Agent': 'Mozilla/5.0'},
        ).timeout(timeout);
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body) as Map<String, dynamic>;
          return _LinkMeta(
            title: data['title']?.toString(),
            description: data['author_name']?.toString(),
            imageUrl: data['thumbnail_url']?.toString(),
            domain: domain,
          );
        }
      }

      // Generic: fetch HTML and parse og: meta tags.
      // Use a browser UA so most news/blog sites serve full OG markup.
      final res = await http.get(uri, headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
      }).timeout(timeout);
      if (res.statusCode == 200) {
        final body = res.body;
        return _LinkMeta(
          title: _extractOgContent(body, 'og:title') ??
              _extractOgContent(body, 'twitter:title'),
          description: _extractOgContent(body, 'og:description') ??
              _extractOgContent(body, 'twitter:description'),
          imageUrl: _extractOgContent(body, 'og:image') ??
              _extractOgContent(body, 'twitter:image'),
          domain: domain,
        );
      }
    } catch (_) {}

    return _LinkMeta(domain: domain);
  }

  static String? _extractOgContent(String html, String property) {
    // OG meta tags always use double-quoted attributes in practice.
    // Matches both: property="og:x" content="y"
    //          and: content="y" property="og:x"
    final e = RegExp.escape(property);
    final re = RegExp(
      '<meta[^>]+(?:property|name)="$e"[^>]+content="([^"]+)"|'
      '<meta[^>]+content="([^"]+)"[^>]+(?:property|name)="$e"',
      caseSensitive: false,
    );
    final m = re.firstMatch(html);
    final value = m?.group(1) ?? m?.group(2);
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  Widget _buildLinkPreview(String url, bool isMe) {
    final maxWidth = MediaQuery.of(context).size.width * 0.72;

    Widget urlChip() => GestureDetector(
          onTap: () => _openLegitLink(url),
          child: Container(
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1A2332),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.link, color: Color(0xFF4FC3F7), size: 16),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    url,
                    style: const TextStyle(
                      color: Color(0xFF4FC3F7),
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: Color(0xFF4FC3F7),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );

    return Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      margin: const EdgeInsets.only(top: 4),
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: FutureBuilder<_LinkMeta>(
        future: _getLinkMeta(url),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2332),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: Color(0xFF4FC3F7),
                    ),
                  ),
                  SizedBox(width: 8),
                  Text('Loading previewâ€¦',
                      style: TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            );
          }

          final meta = snap.data;
          if (meta == null || !meta.hasContent) return urlChip();

          return GestureDetector(
            onTap: () => _openLegitLink(url),
            child: Container(
              constraints: BoxConstraints(maxWidth: maxWidth),
              decoration: BoxDecoration(
                color: const Color(0xFF1A2332),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.hardEdge,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (meta.imageUrl != null)
                    Image.network(
                      meta.imageUrl!,
                      width: double.infinity,
                      height: 140,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (meta.title != null)
                          Text(
                            meta.title!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (meta.description != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            meta.description!,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          meta.domain,
                          style: const TextStyle(
                            color: Color(0xFF4FC3F7),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // â”€â”€ Real SMS message list from Firestore â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  Widget buildSmsMessageList() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _smsMessagesStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Failed to load messages'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!;
        if (docs.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _smsStorage.markAsRead(_smsPeerPhone);
          });
          final latestKey = docs.last['messageId']?.toString() ??
              docs.last['timestampMs']?.toString() ??
              'sms_${docs.length}';
          _scheduleScrollToLatest(latestKey, messageCount: docs.length);
        }

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.sms_outlined, size: 64, color: Colors.grey.shade300),
                const SizedBox(height: 16),
                const Text('No messages yet',
                    style: TextStyle(color: Colors.white54, fontSize: 16)),
                const SizedBox(height: 8),
                const Text('Send a message to start the conversation',
                    style: TextStyle(color: Colors.white38, fontSize: 13)),
                const SizedBox(height: 8),
                const Text(
                  'If a suspicious SMS was blocked, review it in Quarantine Vault.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFFFC266),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          );
        }

        return NotificationListener<ScrollNotification>(
          onNotification: _handleMessageScrollNotification,
          child: ListView.builder(
            key: PageStorageKey<String>('sms_thread_$_smsPeerPhone'),
            controller: _messageScrollController,
            physics: const ClampingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            cacheExtent: 420,
            padding: const EdgeInsets.all(10),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index];
              final isOutgoing =
                  data['isOutgoing'] == true || data['sender'] == 'Me';
              final body = data['body'] ?? data['text'] ?? '';
              final trustedRestore = _isTrustedRestoreData(data);
              final isSuspicious =
                  trustedRestore ? false : (data['isSuspicious'] ?? false);

              final rawSafetyStatusStr = data['safetyStatus']?.toString();

              // Protect UI rendering: if an incoming SMS hasn't been scanned by the pipeline
              // yet (safetyStatus is null), force it into the 'scanning' state to hide the payload.
              final bool isUnscannedIncoming = !isOutgoing &&
                  !trustedRestore &&
                  (rawSafetyStatusStr == null || rawSafetyStatusStr.isEmpty);

              final safetyStatus = trustedRestore
                  ? SafetyStatus.safe
                  : (isUnscannedIncoming
                      ? SafetyStatus.scanning
                      : SafetyStatus.fromValue(rawSafetyStatusStr));
              final status = data['status']?.toString() ?? '';

              DateTime time = DateTime.now();
              final ts = data['timestamp'];
              final timeStr = data['time'];
              if (ts is Timestamp) {
                time = ts.toDate();
              } else if (ts is DateTime) {
                time = ts;
              } else if (timeStr is String) {
                time = DateTime.tryParse(timeStr) ?? DateTime.now();
              }

              final msg = MessageModel(
                text: body,
                isMe: isOutgoing,
                time: time,
                isSuspicious: isSuspicious,
                type: 'text',
                providerId: (data['providerId'] as num?)?.toInt(),
                providerThreadId: data['providerThreadId']?.toString(),
                messageKey: data['messageKey']?.toString(),
                riskScore: (data['riskScore'] as num?)?.toDouble(),
                riskLevel: data['riskLevel']?.toString(),
                detectionReasons: (data['detectionReasons'] as List<dynamic>? ??
                        const <dynamic>[])
                    .map((item) => item.toString())
                    .where((item) => item.trim().isNotEmpty)
                    .toList(),
                modelScore: (data['modelScore'] as num?)?.toDouble(),
                heuristicScore: (data['heuristicScore'] as num?)?.toDouble(),
                detectionSource: data['detectionSource']?.toString(),
                pipelineStage: data['pipelineStage']?.toString(),
                detectionDecision: data['detectionDecision']?.toString(),
                extractedUrls: (data['extractedUrls'] as List<dynamic>? ??
                        const <dynamic>[])
                    .map((item) => item.toString())
                    .where((item) => item.trim().isNotEmpty)
                    .toList(),
                primaryUrl: data['primaryUrl']?.toString(),
                primaryDomain: data['primaryDomain']?.toString(),
                needsRescan:
                    trustedRestore ? false : data['needsRescan'] == true,
                safetyStatus: safetyStatus,
              );

              return RepaintBoundary(
                child: Column(
                  crossAxisAlignment: isOutgoing
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onLongPress: safetyStatus == SafetyStatus.safe
                          ? () => showLocalMessageOptions(msg)
                          : null,
                      child: buildMessageContent(msg),
                    ),
                    buildSuspiciousWarningCard(
                      isSuspicious: isSuspicious,
                      isMe: isOutgoing,
                      riskScore: msg.riskScore,
                      safetyStatus: safetyStatus,
                      onViewQuarantine: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const QuarantineScreen(),
                          ),
                        );
                      },
                      onDeleteForMe: safetyStatus == SafetyStatus.malicious
                          ? () {
                              unawaited(deleteLocalMessage(msg));
                            }
                          : null,
                    ),
                    Padding(
                      padding:
                          const EdgeInsets.only(left: 10, right: 10, bottom: 6),
                      child: Row(
                        mainAxisAlignment: isOutgoing
                            ? MainAxisAlignment.end
                            : MainAxisAlignment.start,
                        children: [
                          Text(formatTime(time),
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                          if (isOutgoing && status.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Text(
                              status[0].toUpperCase() + status.substring(1),
                              style: TextStyle(
                                fontSize: 11,
                                color: status == 'failed'
                                    ? Colors.redAccent
                                    : Colors.grey,
                              ),
                            ),
                          ],
                          if (isSuspicious ||
                              safetyStatus == SafetyStatus.malicious) ...[
                            const SizedBox(width: 6),
                            const Icon(Icons.warning_amber_rounded,
                                size: 14, color: Colors.orange),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget buildLocalMessageList() {
    return buildSmsMessageList();
  }

  Widget _buildOnlineMessageTile({
    required Map<String, dynamic> data,
    required DocumentSnapshot doc,
    required bool isMe,
    required String resolvedText,
    required bool suspicious,
    required String type,
    required bool isCallSummary,
    required DateTime time,
    required String fileName,
    required int editCount,
    required bool isEdited,
    required bool isDeleted,
    required bool hasPendingWrites,
    required SafetyStatus safetyStatus,
    Widget? customContent,
  }) {
    final docPath = doc.reference.path;
    final double? riskScore = (data['riskScore'] as num?)?.toDouble();
    final bool trustedRestore = _isTrustedRestoreData(data);
    final bool isForwarded = data['isForwarded'] == true;
    final bool effectiveSuspicious = !isMe &&
        !trustedRestore &&
        (suspicious ||
            safetyStatus == SafetyStatus.malicious ||
            (riskScore != null && riskScore >= 0.60));

    final MessageModel tempMessage;
    if (isDeleted) {
      tempMessage = MessageModel(
        text: '',
        isMe: isMe,
        time: time,
        isSuspicious: false,
        type: 'deleted',
      );
    } else if (type == 'image' || type == 'gif') {
      tempMessage = MessageModel(
        text: resolvedText,
        isMe: isMe,
        time: time,
        isSuspicious: effectiveSuspicious,
        type: type,
        safetyStatus:
            effectiveSuspicious ? SafetyStatus.malicious : safetyStatus,
        filePath: null,
        detectionDecision: data['detectionDecision']?.toString(),
        detectionSource: data['detectionSource']?.toString(),
        isForwarded: isForwarded,
      );
    } else if (type == 'file') {
      tempMessage = MessageModel(
        text: fileName.isNotEmpty ? fileName : resolvedText,
        isMe: isMe,
        time: time,
        isSuspicious: effectiveSuspicious,
        type: type,
        safetyStatus:
            effectiveSuspicious ? SafetyStatus.malicious : safetyStatus,
        filePath: resolvedText,
        detectionDecision: data['detectionDecision']?.toString(),
        detectionSource: data['detectionSource']?.toString(),
        isForwarded: isForwarded,
      );
    } else {
      tempMessage = MessageModel(
        text: resolvedText,
        isMe: isMe,
        time: time,
        isSuspicious: effectiveSuspicious,
        type: type,
        safetyStatus:
            effectiveSuspicious ? SafetyStatus.malicious : safetyStatus,
        detectionDecision: data['detectionDecision']?.toString(),
        detectionSource: data['detectionSource']?.toString(),
        isForwarded: isForwarded,
      );
    }

    final onlineMsgMap = {
      'text': resolvedText,
      'isMe': isMe,
      'time': formatTime(time),
      'isSuspicious': effectiveSuspicious,
      'type': type,
      'fileName': fileName,
      'docPath': docPath,
      'messageId': doc.id,
      'editCount': editCount,
      'isDeleted': isDeleted,
      'riskScore': riskScore,
      'isForwarded': isForwarded,
      'safetyStatus':
          (effectiveSuspicious ? SafetyStatus.malicious : safetyStatus).value,
    };
    final messageContent = customContent ?? buildMessageContent(tempMessage);

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: isDeleted ||
                    isCallSummary ||
                    safetyStatus == SafetyStatus.scanning ||
                    effectiveSuspicious
                ? null
                : () => showOnlineMessageOptions(onlineMsgMap),
            child: Column(
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isForwarded && !isDeleted && !isCallSummary)
                  _buildForwardedIndicator(isMe: isMe),
                messageContent,
              ],
            ),
          ),
          if (!isDeleted && !isCallSummary)
            buildSuspiciousWarningCard(
              isSuspicious: effectiveSuspicious,
              isMe: isMe,
              riskScore: riskScore,
              onViewQuarantine: effectiveSuspicious
                  ? () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const QuarantineScreen(),
                        ),
                      );
                    }
                  : null,
              onDeleteForMe: effectiveSuspicious
                  ? () {
                      _confirmDeleteOnline(doc.id, isMe);
                    }
                  : null,
              safetyStatus:
                  effectiveSuspicious ? SafetyStatus.malicious : safetyStatus,
            ),
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 10, bottom: 6),
            child: Column(
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment:
                      isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                  children: [
                    if (isEdited && !isDeleted && !isCallSummary)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          'edited',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade400,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    Text(
                      formatTime(time),
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                    if (effectiveSuspicious &&
                        !isDeleted &&
                        !isCallSummary) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 14,
                        color: Colors.orange,
                      ),
                    ],
                    if (isMe && !isDeleted && !isCallSummary) ...[
                      const SizedBox(width: 4),
                      Icon(
                        hasPendingWrites ? Icons.access_time : Icons.done_all,
                        size: 14,
                        color: hasPendingWrites
                            ? Colors.white38
                            : ((data['isRead'] == true)
                                ? const Color(0xFF25D366)
                                : Colors.grey),
                      ),
                      if (hasPendingWrites) ...[
                        const SizedBox(width: 4),
                        const Text(
                          'Sending...',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white38,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget buildOnlineMessageList() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _onlineMessagesStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Failed to load messages'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = _resolveOnlineDocs(snapshot.data!);
        if (docs.isNotEmpty) {
          _scheduleScrollToLatest(docs.first.id, messageCount: docs.length);
        }

        return StreamBuilder<bool>(
          stream: onlineChatService.getIsTyping(otherUserId: otherUserId),
          builder: (context, typingSnap) {
            final isTyping = typingSnap.data ?? false;
            return NotificationListener<ScrollNotification>(
              onNotification: _handleMessageScrollNotification,
              child: ListView.builder(
                key: PageStorageKey<String>('online_thread_$otherUserId'),
                controller: _messageScrollController,
                reverse: true,
                physics: const ClampingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                cacheExtent: 460,
                padding: const EdgeInsets.all(10),
                itemCount: docs.length + (isTyping ? 1 : 0),
                itemBuilder: (context, index) {
                  if (isTyping && index == 0) {
                    return const _TypingIndicatorBubble();
                  }
                  final doc = docs[isTyping ? index - 1 : index];
                  final data = doc.data();
                  final isMe = data['senderId'] == currentUserId;
                  final text = data['text']?.toString() ?? '';
                  final suspicious = data['isSuspicious'] ?? false;
                  final rawType =
                      (data['type'] ?? data['messageType'] ?? 'text')
                          .toString();
                  final type = rawType;
                  final isCallSummary = type == 'call_summary';
                  final time = _extractBestMessageTime(data);
                  final fileName = data['fileName'] as String? ?? '';
                  final editCount = data['editCount'] as int? ?? 0;
                  final hasPendingWrites = doc.metadata.hasPendingWrites;
                  final isEdited = editCount > 0;
                  final isDeleted =
                      data['isDeleted'] == true || type == 'deleted';
                  final rawSafetyStatus =
                      SafetyStatus.fromValue(data['safetyStatus']?.toString());
                  final trustedRestore = _isTrustedRestoreData(data);
                  final screenedForReceiverId =
                      data['screenedForReceiverId']?.toString() ?? '';
                  final safetyStatus = isMe
                      ? SafetyStatus.safe
                      : (!isDeleted &&
                              type != 'call_summary' &&
                              !trustedRestore &&
                              screenedForReceiverId != currentUserId &&
                              rawSafetyStatus != SafetyStatus.malicious
                          ? SafetyStatus.scanning
                          : (trustedRestore
                              ? SafetyStatus.safe
                              : rawSafetyStatus));

                  var resolvedText = text;
                  if (!isDeleted &&
                      type == 'text' &&
                      resolvedText.trim().isEmpty) {
                    resolvedText = 'Message unavailable';
                  }

                  return RepaintBoundary(
                    child: _buildOnlineMessageTile(
                      data: data,
                      doc: doc,
                      isMe: isMe,
                      resolvedText: resolvedText,
                      suspicious: suspicious,
                      type: type,
                      isCallSummary: isCallSummary,
                      time: time,
                      fileName: fileName,
                      editCount: editCount,
                      isEdited: isEdited,
                      isDeleted: isDeleted,
                      hasPendingWrites: hasPendingWrites,
                      safetyStatus: safetyStatus,
                    ),
                  );
                },
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isSms = widget.chatType == 'sms';

    return Scaffold(
      backgroundColor: _screenBackground,
      appBar: AppBar(
        backgroundColor: getHeaderColor(),
        elevation: 0,
        title: widget.chatType == 'online' && widget.receiverId != null
            ? StreamBuilder<DocumentSnapshot>(
                stream: onlineChatService.getUserStatus(widget.receiverId!),
                builder: (context, snapshot) {
                  bool isOnline = false;
                  String subtitle = '';
                  String presenceMode = 'online';
                  String? photoUrl;
                  var resolvedDisplayName = _displayName;
                  if (snapshot.hasData && snapshot.data!.exists) {
                    final data = snapshot.data!.data() as Map<String, dynamic>?;
                    isOnline = OnlineChatService.computeEffectiveOnline(data);
                    presenceMode = OnlineChatService.normalizePresenceMode(
                      data?['presenceMode']?.toString(),
                    );
                    photoUrl = data?['photoUrl']?.toString();
                    resolvedDisplayName = UserProfileService.resolveDisplayName(
                      data: data,
                      fallback: _displayName,
                    );
                    if (!isOnline) {
                      subtitle = _formatLastSeen(data?['lastSeen']);
                    }
                  }
                  return Row(
                    children: [
                      UserAvatar(
                        name: resolvedDisplayName,
                        imageUrl: photoUrl,
                        radius: 20,
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.grey,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: StreamBuilder<bool>(
                          stream: onlineChatService.getIsTyping(
                            otherUserId: otherUserId,
                          ),
                          builder: (context, typingSnap) {
                            final isTyping = typingSnap.data ?? false;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(resolvedDisplayName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    )),
                                if (isTyping)
                                  const Text('typing...',
                                      style: TextStyle(
                                          color: Color(0xFF25D366),
                                          fontSize: 12,
                                          fontStyle: FontStyle.italic))
                                else if (_presenceLabel(presenceMode, isOnline)
                                    .isNotEmpty)
                                  Row(
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        margin: const EdgeInsets.only(right: 6),
                                        decoration: BoxDecoration(
                                          color: _presenceColor(
                                            presenceMode,
                                            isOnline,
                                          ),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      Text(
                                        _presenceLabel(
                                          presenceMode,
                                          isOnline,
                                        ),
                                        style: TextStyle(
                                          color: _presenceColor(
                                            presenceMode,
                                            isOnline,
                                          ),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  )
                                else if (subtitle.isNotEmpty)
                                  Text(subtitle,
                                      style: const TextStyle(
                                          color: Colors.white60, fontSize: 12)),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              )
            : Row(
                children: [
                  UserAvatar(
                    name: _displayName,
                    radius: 20,
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.grey,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _displayName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
        actions: _buildChatActions(isSms),
      ),
      body: Container(
        decoration: BoxDecoration(
          color: _screenBackground,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              const Color(0xFF0E1A28),
              _screenBackground,
              const Color(0xFF09111B),
            ],
          ),
        ),
        child: Column(
          children: [
            if (isSms) _buildModeBanner(isSms: isSms),
            if (!isSms) _buildConnectionBanner(),
            Expanded(
              child: isSms ? buildLocalMessageList() : buildOnlineMessageList(),
            ),
            if (_isUploading)
              Container(
                color: _surfaceColor,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF25D366),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Uploading... ${(_uploadProgress * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: _uploadProgress,
                      backgroundColor: Colors.white10,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF25D366),
                      ),
                    ),
                  ],
                ),
              ),
            if (_editingMessageId != null)
              Container(
                color: const Color(0xFF123129),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: Color(0xFF7CE9B6),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Editing message (${3 - _editingCount} edit${3 - _editingCount == 1 ? '' : 's'} remaining)',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFFB8F8DA),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: _cancelEditing,
                      child: const Icon(
                        Icons.close,
                        size: 18,
                        color: Color(0xFFB8F8DA),
                      ),
                    ),
                  ],
                ),
              ),
            if (!isSms && _isConversationBlocked)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF2B1A1C),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.redAccent.withValues(alpha: 0.28),
                  ),
                ),
                child: Text(
                  _blockedBannerText,
                  style: const TextStyle(
                    color: Color(0xFFFFB6B6),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
              decoration: BoxDecoration(
                color: _surfaceColor,
                border: Border(top: BorderSide(color: _outlineColor)),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 14,
                    offset: Offset(0, -4),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    if (!isSms)
                      Container(
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: _surfaceElevatedColor,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.add_circle_outline,
                            color: Color(0xFF7CE9B6),
                          ),
                          onPressed: _isConversationBlocked
                              ? null
                              : _showAttachmentPicker,
                        ),
                      ),
                    Expanded(
                      child: TextField(
                        enabled: !_isConversationBlocked,
                        controller: messageController,
                        focusNode: _messageFocusNode,
                        onTap: () {
                          FocusScope.of(context)
                              .requestFocus(_messageFocusNode);
                          onTyping();
                        },
                        onChanged: (_) => onTyping(),
                        maxLines: null,
                        style: const TextStyle(color: Colors.white),
                        cursorColor: const Color(0xFF25D366),
                        decoration: InputDecoration(
                          hintText: _editingMessageId != null
                              ? 'Edit message...'
                              : isSms
                                  ? 'Type SMS message'
                                  : 'Type online message',
                          hintStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: _inputFillColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(25),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 10,
                          ),
                        ),
                      ),
                    ),
                    if (isSms) ...[
                      const SizedBox(width: 4),
                      InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: _showSmsSimPicker,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: _surfaceElevatedColor,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: _outlineColor),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.sim_card_outlined,
                                size: 17,
                                color: Color(0xFF7CE9B6),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                _selectedSmsSimLabel,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 2),
                              const Icon(
                                Icons.arrow_drop_down,
                                color: Colors.white70,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(width: 5),
                    CircleAvatar(
                      backgroundColor: _editingMessageId != null
                          ? const Color(0xFF075E54)
                          : isSms
                              ? const Color(0xFFE28B28)
                              : const Color(0xFF25D366),
                      child: IconButton(
                        icon: Icon(
                          _isSendingMessage
                              ? Icons.hourglass_top
                              : _editingMessageId != null
                                  ? Icons.check
                                  : Icons.send,
                          color: Colors.white,
                        ),
                        onPressed: (_isSendingMessage || _isConversationBlocked)
                            ? null
                            : sendMessage,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RiskyLinkDialog extends StatefulWidget {
  final String defangedUrl;
  final Duration countdown;

  const _RiskyLinkDialog({
    required this.defangedUrl,
    required this.countdown,
  });

  @override
  State<_RiskyLinkDialog> createState() => _RiskyLinkDialogState();
}

class _RiskyLinkDialogState extends State<_RiskyLinkDialog> {
  Timer? _countdownTimer;
  late int _secondsLeft;

  @override
  void initState() {
    super.initState();
    _secondsLeft = widget.countdown.inSeconds;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft <= 1) {
        timer.cancel();
        if (mounted) {
          setState(() => _secondsLeft = 0);
        }
        return;
      }
      if (mounted) {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canOpen = _secondsLeft == 0;

    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.shield_outlined, color: Colors.orange),
          SizedBox(width: 10),
          Expanded(
            child: Text('Security Check Required'),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This link will open outside Smishing Shield PH. Open it only if you trust the sender and the website.',
              style: TextStyle(fontSize: 14, height: 1.35),
            ),
            const SizedBox(height: 10),
            const Text(
              'Magbubukas ang link sa labas ng app. Buksan lang ito kung pinagkakatiwalaan mo ang sender at website.',
              style: TextStyle(fontSize: 13, height: 1.35),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFCC80)),
              ),
              child: SelectableText(
                widget.defangedUrl,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Watch for fake verification, urgent requests, OTP theft, and impersonation.',
              style: TextStyle(fontSize: 12.5, color: Colors.black87),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor:
                canOpen ? const Color(0xFF075E54) : Colors.grey.shade300,
          ),
          onPressed: canOpen ? () => Navigator.pop(context, true) : null,
          child: Text(
            canOpen ? 'Open Link' : 'Open in ${_secondsLeft}s',
            style: TextStyle(
              color: canOpen ? Colors.white : Colors.grey.shade600,
            ),
          ),
        ),
      ],
    );
  }
}

class _TypingIndicatorBubble extends StatefulWidget {
  const _TypingIndicatorBubble();

  @override
  State<_TypingIndicatorBubble> createState() => _TypingIndicatorBubbleState();
}

class _LinkMeta {
  final String? title;
  final String? description;
  final String? imageUrl;
  final String domain;
  const _LinkMeta({
    this.title,
    this.description,
    this.imageUrl,
    required this.domain,
  });
  bool get hasContent => title != null || description != null;
}

class _ForwardRecipient {
  const _ForwardRecipient({
    required this.uid,
    required this.name,
    this.email,
  });

  final String uid;
  final String name;
  final String? email;
}

class _GifPickerSheet extends StatefulWidget {
  const _GifPickerSheet({required this.gifSearchService});

  final GifSearchService gifSearchService;

  @override
  State<_GifPickerSheet> createState() => _GifPickerSheetState();
}

class _GifPickerSheetState extends State<_GifPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  Future<List<GifResult>>? _resultsFuture;
  Timer? _debounceTimer;

  static const Color _inputFillColor = Color(0xFF1A2737);
  static const Color _accentColor = Color(0xFF25D366);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
    _loadResults();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 350), _loadResults);
  }

  void _loadResults() {
    setState(() {
      _resultsFuture = widget.gifSearchService.fetch(
        query: _searchController.text,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.48,
        maxChildSize: 0.94,
        builder: (context, scrollController) {
          return Column(
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 10, bottom: 14),
                decoration: const BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'GIF',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      'Powered by GIPHY',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  cursorColor: _accentColor,
                  decoration: InputDecoration(
                    hintText: 'Search GIFs',
                    hintStyle: const TextStyle(color: Colors.white54),
                    prefixIcon: const Icon(Icons.search, color: Colors.white70),
                    suffixIcon: _searchController.text.trim().isNotEmpty
                        ? IconButton(
                            onPressed: () {
                              _searchController.clear();
                              _loadResults();
                            },
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white54,
                              size: 18,
                            ),
                          )
                        : null,
                    filled: true,
                    fillColor: _inputFillColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: !widget.gifSearchService.isConfigured
                    ? const _GifConfigEmptyState()
                    : FutureBuilder<List<GifResult>>(
                        future: _resultsFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return const Center(
                              child: CircularProgressIndicator(
                                color: _accentColor,
                              ),
                            );
                          }
                          if (snapshot.hasError) {
                            return Center(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 28),
                                child: Text(
                                  snapshot.error.toString(),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            );
                          }
                          final gifs = snapshot.data ?? const <GifResult>[];
                          if (gifs.isEmpty) {
                            return const Center(
                              child: Text(
                                'No GIFs found.',
                                style: TextStyle(color: Colors.white70),
                              ),
                            );
                          }
                          return GridView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              childAspectRatio: 1,
                            ),
                            itemCount: gifs.length,
                            itemBuilder: (context, index) {
                              final gif = gifs[index];
                              return _GifTile(
                                gif: gif,
                                onTap: () => Navigator.pop(context, gif),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _GifTile extends StatelessWidget {
  const _GifTile({
    required this.gif,
    required this.onTap,
  });

  final GifResult gif;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A2737),
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Image.network(
          gif.previewUrl,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const Center(
            child: Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
            ),
          ),
          loadingBuilder: (_, child, progress) {
            if (progress == null) return child;
            return const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Color(0xFF25D366),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _GifConfigEmptyState extends StatelessWidget {
  const _GifConfigEmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.key_off_outlined, color: Colors.white54, size: 32),
            SizedBox(height: 12),
            Text(
              'GIPHY API key missing',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Run the app with --dart-define=GIPHY_API_KEY=your_key to override the default key.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, height: 1.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _TypingIndicatorBubbleState extends State<_TypingIndicatorBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4, right: 60),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            return AnimatedBuilder(
              animation: _controller,
              builder: (_, __) {
                final phase = (_controller.value + i / 3.0) % 1.0;
                final opacity = (0.3 + 0.7 * (0.5 + 0.5 * sin(phase * 2 * pi)))
                    .clamp(0.0, 1.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Opacity(
                    opacity: opacity,
                    child: const Text(
                      'â€¢',
                      style: TextStyle(
                        fontSize: 20,
                        color: Color(0xFF25D366),
                        height: 1.0,
                      ),
                    ),
                  ),
                );
              },
            );
          }),
        ),
      ),
    );
  }
}
