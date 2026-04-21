import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message_model.dart';
import '../models/decrypted_conversation_message.dart';
import '../services/chat_encryption_repository.dart';
import '../services/chat_notification_service.dart';
import '../services/call_notification_service.dart';
import '../services/cloudinary_service.dart';
import '../services/device_contact_sync_service.dart';
import '../services/e2ee_service.dart';
import '../services/feedback_service.dart';
import '../services/feedback_database_service.dart';
import '../services/fcm_chat_service.dart';
import '../services/media_service.dart';
import '../services/online_chat_service.dart';
import '../services/sms_service.dart';
import '../services/sms_storage_service.dart';
import '../services/trusted_domain_service.dart';
import '../services/url_extraction_service.dart';
import '../services/user_profile_service.dart';
import '../widgets/feedback_upload_consent_dialog.dart';
import '../widgets/message_bubble.dart';
import '../widgets/user_avatar.dart';
import 'call_screen.dart';

enum _ChatMenuAction {
  muteNotifications,
  unmuteNotifications,
  blockUser,
  unblockUser,
  markUnread,
  markRead,
  resetSecureSession,
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
  final FcmChatService _fcmChatService = FcmChatService();
  final CloudinaryService _cloudinaryService = CloudinaryService();
  final SmsStorageService _smsStorage = SmsStorageService();
  final FeedbackService _feedbackService = FeedbackService();
  final E2eeService _e2eeService = E2eeService();
  final ChatEncryptionRepository _chatEncryptionRepository =
      ChatEncryptionRepository();
  final UserProfileService _userProfileService = UserProfileService();
  final TrustedDomainService _trustedDomainService = TrustedDomainService();
  final UrlExtractionService _urlExtractionService = UrlExtractionService();
  final Map<String, Future<String>> _decryptedTextFutures =
      <String, Future<String>>{};
  final Map<String, Future<Uint8List>> _encryptedMediaFutures =
      <String, Future<Uint8List>>{};
  final Map<String, DateTime> _decryptedTextFailureAt = <String, DateTime>{};
  final Map<String, DateTime> _encryptedMediaFailureAt = <String, DateTime>{};
  final Queue<Completer<void>> _textDecryptWaiters = Queue<Completer<void>>();
  final Queue<Completer<void>> _mediaDecryptWaiters = Queue<Completer<void>>();

  static const int _maxFileSizeBytes = 25 * 1024 * 1024;
  static const int _maxConcurrentTextDecrypts = 2;
  static const int _maxConcurrentMediaDecrypts = 1;
  static const Duration _decryptFailureCooldown = Duration(seconds: 5);
  static const Duration _externalLinkCountdown = Duration(seconds: 4);

  Timer? _typingTimer;
  bool _isUploading = false;
  bool _isSendingMessage = false;
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
  int _activeTextDecrypts = 0;
  int _activeMediaDecrypts = 0;

  // Edit state
  String? _editingMessageId;
  int _editingCount = 0;

  late Stream<QuerySnapshot<Map<String, dynamic>>> _onlineMessagesStream;
  late Stream<List<Map<String, dynamic>>> _smsMessagesStream;

  String get currentUserId => FirebaseAuth.instance.currentUser?.uid ?? '';
  String get otherUserId => widget.receiverId ?? widget.phone;
  String? _lastRenderedMessageKey;
  String? _lastConversationSnapshotSyncKey;
  bool _didInitialConversationHistorySync = false;
  String? _cachedOnlineDocsKey;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _cachedOnlineDocs =
      const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  String? _cachedProjectionLookupKey;
  _ConversationProjectionLookups _cachedProjectionLookups =
      const _ConversationProjectionLookups.empty();

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

  Future<void> _primeOnlineConversationSecurity() async {
    if (widget.chatType != 'online' || otherUserId.isEmpty) {
      return;
    }
    try {
      await _e2eeService.ensureReady(syncRemote: false);
      await _e2eeService.prewarmConversation(otherUserId);
    } catch (error) {
      debugPrint(
        '[ChatScreen] Failed to prewarm encrypted conversation for $otherUserId: $error',
      );
    }
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
      unawaited(_refreshChatRelationship());
      unawaited(_primeOnlineConversationSecurity());
      unawaited(
        _chatEncryptionRepository.primeConversation(otherUserId: otherUserId),
      );
      ChatNotificationService()
          .setActiveChat(onlineChatService.getChatId(otherUserId));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onlineChatService.markMessagesAsRead(otherUserId);
      });
    }
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
    if (widget.chatType == 'online') {
      ChatNotificationService().setActiveChat(null);
      onlineChatService.setTyping(otherUserId: otherUserId, isTyping: false);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.chatType == 'sms') {
      unawaited(_refreshSmsContactDisplayName());
      unawaited(_loadSmsCapabilityState());
      unawaited(SmsService.primeSmsThread(address: _smsPeerPhone, force: true));
      unawaited(SmsService.scheduleInboxMaintenance());
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

  // ── Permissions ───────────────────────────────────────────────────────
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

  // ── Open URL ──────────────────────────────────────────────────────────
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
                    ),
                  ),
                  PopupMenuItem<_ChatMenuAction>(
                    value: _blockedByMe
                        ? _ChatMenuAction.unblockUser
                        : _ChatMenuAction.blockUser,
                    child: Text(_blockedByMe ? 'Unblock user' : 'Block user'),
                  ),
                  PopupMenuItem<_ChatMenuAction>(
                    value: _manuallyUnread
                        ? _ChatMenuAction.markRead
                        : _ChatMenuAction.markUnread,
                    child: Text(
                      _manuallyUnread ? 'Mark as read' : 'Mark as unread',
                    ),
                  ),
                  const PopupMenuItem<_ChatMenuAction>(
                    value: _ChatMenuAction.resetSecureSession,
                    child: Text('Reset secure session'),
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
        case _ChatMenuAction.resetSecureSession:
          await _chatEncryptionRepository.resetPeerSession(otherUserId);
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Secure session reset. Send a message to reconnect.',
              ),
            ),
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

  String _buildConversationSnapshotSyncKey({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required List<DocumentChange<Map<String, dynamic>>> docChanges,
  }) {
    final latestDoc = docs.isNotEmpty ? docs.first : null;
    final latestTimestampMs = latestDoc == null
        ? 0
        : _extractBestMessageTime(latestDoc.data()).millisecondsSinceEpoch;
    final changeSignature = docChanges.isEmpty
        ? 'none'
        : docChanges.map((change) {
            final changedTimestampMs = _extractBestMessageTime(
              change.doc.data() ?? const <String, dynamic>{},
            ).millisecondsSinceEpoch;
            return '${_documentChangeTypeKey(change.type)}:'
                '${change.doc.id}:$changedTimestampMs';
          }).join('|');
    return '$otherUserId|${docs.length}|${latestDoc?.id ?? ''}|'
        '$latestTimestampMs|$changeSignature';
  }

  void _scheduleConversationSnapshotSync({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required List<DocumentChange<Map<String, dynamic>>> docChanges,
  }) {
    final syncKey = _buildConversationSnapshotSyncKey(
      docs: docs,
      docChanges: docChanges,
    );
    if (_lastConversationSnapshotSyncKey == syncKey) {
      return;
    }
    _lastConversationSnapshotSyncKey = syncKey;

    final incrementalChanges =
        _didInitialConversationHistorySync ? docChanges : null;
    _didInitialConversationHistorySync = true;

    unawaited(
      _syncConversationSnapshotGuarded(
        docs: docs,
        docChanges: incrementalChanges,
      ),
    );
  }

  Future<void> _syncConversationSnapshotGuarded({
    required List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    required List<DocumentChange<Map<String, dynamic>>>? docChanges,
  }) async {
    try {
      await _e2eeService.ensureReady(syncRemote: false);
      await _chatEncryptionRepository.syncConversationSnapshot(
        otherUserId: otherUserId,
        docs: docs,
        docChanges: docChanges,
      );
    } catch (error) {
      debugPrint(
        '[ChatScreen] Deferred conversation snapshot sync failed for '
        '$otherUserId: $error',
      );
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

  _ConversationProjectionLookups _resolveProjectionLookups(
    List<DecryptedConversationMessage> projections,
  ) {
    final cacheKey = projections.isEmpty
        ? 'empty'
        : Object.hashAll(
            projections.map(
              (projection) => '${projection.messageId ?? ''}|'
                  '${projection.clientMessageId ?? ''}|'
                  '${projection.messageKey}|'
                  '${projection.decryptionStatus.value}|'
                  '${projection.timestamp.millisecondsSinceEpoch}|'
                  '${projection.isDeleted ? 1 : 0}',
            ),
          ).toString();
    if (_cachedProjectionLookupKey == cacheKey) {
      return _cachedProjectionLookups;
    }

    final byMessageId = <String, DecryptedConversationMessage>{
      for (final projection in projections)
        if ((projection.messageId ?? '').isNotEmpty)
          projection.messageId!: projection,
    };
    final byClientMessageId = <String, DecryptedConversationMessage>{
      for (final projection in projections)
        if ((projection.clientMessageId ?? '').isNotEmpty)
          projection.clientMessageId!: projection,
    };
    final byCacheKey = <String, DecryptedConversationMessage>{
      for (final projection in projections)
        if (projection.messageKey.trim().isNotEmpty)
          projection.messageKey.trim(): projection,
    };

    _cachedProjectionLookupKey = cacheKey;
    _cachedProjectionLookups = _ConversationProjectionLookups(
      byMessageId: byMessageId,
      byClientMessageId: byClientMessageId,
      byCacheKey: byCacheKey,
    );
    return _cachedProjectionLookups;
  }

  bool _looksEncryptedTextMessage(
    Map<String, dynamic> data,
    DecryptedConversationMessage? projection,
  ) {
    final type = (data['type'] ?? data['messageType'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final hasCipherText = <String>[
      'cipherText',
      'ciphertext',
      'encryptedPayload',
      'encryptedText',
      'encrypted_payload',
      'cipher',
    ].any((key) => data[key]?.toString().trim().isNotEmpty ?? false);

    if (projection != null &&
        projection.messageType == 'text' &&
        projection.cipherTextPresent &&
        (hasCipherText ||
            data['e2ee'] == true ||
            (projection.algorithm?.trim().isNotEmpty ?? false))) {
      return true;
    }

    final maybeTextType = type.isEmpty ||
        type == 'text' ||
        type == 'encrypted_text' ||
        type == 'message';
    return maybeTextType && data['e2ee'] == true && hasCipherText;
  }

  void onTyping() {
    if (widget.chatType != 'online') return;
    onlineChatService.setTyping(otherUserId: otherUserId, isTyping: true);
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      onlineChatService.setTyping(otherUserId: otherUserId, isTyping: false);
    });
  }

  // ── Send / Edit text message ──────────────────────────────────────────
  Future<void> sendMessage() async {
    final text = messageController.text.trim();
    if (text.isEmpty) return; // Removed _isSendingMessage check for fast sending
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
    _scrollToBottom(immediate: false);

    if (widget.chatType == 'sms') {
      if (!_smsCanSendFromApp) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Set Smishing Shield PH as the default SMS app to send SMS reliably.')
        ));
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
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('SMS Send failed: $e')));
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
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to send GIF: $e')));
        }));
      } else {
        // Fire-and-forget text
        unawaited(onlineChatService.sendMessage(
          receiverId: otherUserId,
          text: text,
          receiverName: _displayName,
        ).catchError((Object e) {
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

  // ── Camera ────────────────────────────────────────────────────────────
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

  // ── Send image from gallery ───────────────────────────────────────────
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
    if (!mounted) return;
    FocusScope.of(context).requestFocus(_messageFocusNode);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Use your keyboard GIF button or paste a direct GIF link, then tap send.',
        ),
      ),
    );
  }

  // ── Send file ─────────────────────────────────────────────────────────
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

  // ── Save media to Firestore ───────────────────────────────────────────
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
      'e2ee': false,
      'e2eeMedia': false,
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
        'e2ee': false,
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
      'e2ee': false,
      'e2eeMedia': false,
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
        'e2ee': false,
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
    if (host == 'media.tenor.com' || host.endsWith('.media.tenor.com')) {
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

  // ── Show attachment picker ────────────────────────────────────────────
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

  void deleteLocalMessage(MessageModel msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Message deleted.')));
  }

  void ignoreWarning() {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Warning ignored.')));
  }

  Future<void> reportLocalMessage(MessageModel msg) async {
    try {
      await ensureFeedbackUploadPreference(context);
      
      // Buffer the anonymized report in SQLite (Confirmed Smishing)
      final feedbackDbService = FeedbackDatabaseService();
      await feedbackDbService.saveConfirmedSmishing(
        message: msg.text,
        source: 'sms',
        sender: _smsPeerPhone,
      );

      await _feedbackService.reportSmsMessageAsSmishing(
        peer: _smsPeerPhone,
        message: msg,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message reported to quarantine.')));
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
      
      // Buffer the anonymized report in SQLite (Confirmed Smishing)
      final feedbackDbService = FeedbackDatabaseService();
      await feedbackDbService.saveConfirmedSmishing(
        message: messageText,
        source: 'online',
        sender: otherUserId,
      );

      await onlineChatService.reportMessageToQuarantine(
        sender: _displayName,
        message: messageText,
        source: 'online',
        messageDocPath: docPath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message reported to quarantine.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to report: $e')));
    }
  }

  Future<void> reportFalseNegativeLocal(MessageModel msg) async {
    try {
      await ensureFeedbackUploadPreference(context);
      
      // Rule 4: Buffer the anonymized report in SQLite (False Negative)
      final feedbackDbService = FeedbackDatabaseService();
      await feedbackDbService.saveFalseNegative(
        message: msg.text,
        source: 'sms',
        sender: _smsPeerPhone,
      );

      await _feedbackService.reportSmsMessageAsSmishing(
        peer: _smsPeerPhone,
        message: msg,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Reported as smishing. Thank you!'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
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
      
      // Rule 4: Buffer the anonymized report in SQLite (False Negative)
      final feedbackDbService = FeedbackDatabaseService();
      await feedbackDbService.saveFalseNegative(
        message: messageText,
        source: 'online',
        sender: otherUserId,
      );

      await onlineChatService.reportMessageToQuarantine(
        sender: _displayName,
        message: messageText,
        source: 'false_negative_online',
        messageDocPath: docPath,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Reported as smishing. Thank you!'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to report: $e')));
    }
  }

  // ── Local message options (SMS) ───────────────────────────────────────
  void showLocalMessageOptions(MessageModel msg) {
    final urls = _urlExtractionService.extractUrls(msg.text);
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Wrap(children: [
          if (msg.text.trim().isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy Message'),
              onTap: () async {
                Navigator.pop(context);
                await _copyText(
                  msg.text,
                  successText: 'Message copied',
                );
              },
            ),
          if (urls.isNotEmpty)
            ListTile(
              leading: Icon(
                _trustedDomainService.isUrlTrustedCached(urls.first)
                    ? Icons.open_in_new
                    : Icons.shield_outlined,
                color: _trustedDomainService.isUrlTrustedCached(urls.first)
                    ? const Color(0xFF075E54)
                    : Colors.orange,
              ),
              title: Text(
                _trustedDomainService.isUrlTrustedCached(urls.first)
                    ? 'Open Link'
                    : 'Security Check Before Opening',
              ),
              subtitle: Text(urls.first,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () async {
                Navigator.pop(context);
                await _openLegitLink(urls.first);
              },
            ),
          if (msg.isSuspicious)
            ListTile(
              leading:
                  const Icon(Icons.report_gmailerrorred, color: Colors.orange),
              title: const Text('Report to Quarantine'),
              onTap: () {
                Navigator.pop(context);
                reportLocalMessage(msg);
              },
            ),
          if (!msg.isSuspicious)
            ListTile(
              leading:
                  const Icon(Icons.warning_amber_rounded, color: Colors.red),
              title: const Text('Report as Smishing'),
              onTap: () {
                Navigator.pop(context);
                reportFalseNegativeLocal(msg);
              },
            ),
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined),
            title: const Text('Ignore Warning'),
            onTap: () {
              Navigator.pop(context);
              ignoreWarning();
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.red),
            title: const Text('Delete Message'),
            onTap: () {
              Navigator.pop(context);
              deleteLocalMessage(msg);
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

  // ── Online message options ────────────────────────────────────────────
  void showOnlineMessageOptions(Map<String, dynamic> msg) {
    final isMe = msg['isMe'] == true;
    final msgId = msg['messageId'] ?? '';
    final msgText = msg['text'] ?? '';
    final msgType = msg['type'] ?? 'text';
    final editCount = msg['editCount'] as int? ?? 0;
    final isDeleted = msg['isDeleted'] == true;
    final urls = _urlExtractionService.extractUrls(msgText);

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Wrap(children: [
          if (!isDeleted && msgText.toString().trim().isNotEmpty)
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy Message'),
              onTap: () async {
                Navigator.pop(context);
                await _copyText(
                  msgText.toString(),
                  successText: 'Message copied',
                );
              },
            ),
          if (!isDeleted && urls.isNotEmpty)
            ListTile(
              leading: Icon(
                _trustedDomainService.isUrlTrustedCached(urls.first)
                    ? Icons.open_in_new
                    : Icons.shield_outlined,
                color: _trustedDomainService.isUrlTrustedCached(urls.first)
                    ? const Color(0xFF075E54)
                    : Colors.orange,
              ),
              title: Text(
                _trustedDomainService.isUrlTrustedCached(urls.first)
                    ? 'Open Link'
                    : 'Security Check Before Opening',
              ),
              subtitle: Text(urls.first,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () async {
                Navigator.pop(context);
                await _openLegitLink(urls.first);
              },
            ),
          if (isMe && msgType == 'text' && !isDeleted && editCount < 3)
            ListTile(
              leading:
                  const Icon(Icons.edit_outlined, color: Color(0xFF075E54)),
              title: const Text('Edit Message'),
              subtitle: Text(
                  'Can edit ${3 - editCount} more time${3 - editCount == 1 ? '' : 's'}'),
              onTap: () {
                Navigator.pop(context);
                _startEditing(msgId, msgText, editCount);
              },
            ),
          if (!isDeleted)
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text(isMe ? 'Delete Message' : 'Delete for Me'),
              subtitle: Text(isMe
                  ? 'Deletes for everyone'
                  : 'Only removes from your view'),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteOnline(msgId, isMe);
              },
            ),
          if (!isMe && msg['isSuspicious'] == true && !isDeleted)
            ListTile(
              leading:
                  const Icon(Icons.report_gmailerrorred, color: Colors.orange),
              title: const Text('Report to Quarantine'),
              onTap: () {
                Navigator.pop(context);
                reportOnlineMessage(msg);
              },
            ),
          if (!isMe && msg['isSuspicious'] != true && !isDeleted)
            ListTile(
              leading:
                  const Icon(Icons.warning_amber_rounded, color: Colors.red),
              title: const Text('Report as Smishing'),
              subtitle: const Text('AI missed this'),
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

  void _startEditing(String messageId, String currentText, int editCount) {
    setState(() {
      _editingMessageId = messageId;
      _editingCount = editCount;
      messageController.text = currentText;
    });
    FocusScope.of(context).requestFocus(FocusNode());
  }

  void _cancelEditing() {
    setState(() {
      _editingMessageId = null;
      _editingCount = 0;
      messageController.clear();
    });
  }

  // ── Confirm delete online message ─────────────────────────────────────
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
    final title = isSms ? 'SMS protection is active' : 'Encrypted online chat';
    final subtitle = isSms
        ? (_smsCanSendFromApp
            ? 'This SMS thread is synced from the Android SMS provider. Suspicious SMS may be flagged or moved into quarantine.'
            : 'Limited mode: you can review synced SMS here, but reliable send/receive requires Smishing Shield PH to be the default SMS app.')
        : 'Messages are delivered in real time with end-to-end encryption.';

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

  Widget buildSuspiciousWarningCard({
    required bool isSuspicious,
    required bool isMe,
  }) {
    if (!isSuspicious) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.only(
          left: isMe ? 60 : 10, right: isMe ? 10 : 60, bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF2F2315),
        border:
            Border.all(color: const Color(0xFFE28B28).withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Suspicious message detected. Avoid links, OTPs, urgent requests, and sender impersonation.\nKahina-hinala ang mensaheng ito. Iwasan ang link, OTP, pagmamadali, at panggagaya ng sender.',
              style: TextStyle(fontSize: 12, color: Color(0xFFFFD49A)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Message content builder ───────────────────────────────────────────
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

    if (msg.type == 'image' || msg.type == 'gif') {
      final isUrl = msg.text.startsWith('http');
      return GestureDetector(
        onTap: () async {
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
        onTap: isUrl ? () => _openLegitLink(fileUrl) : null,
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

    return MessageBubble(text: msg.text, isMe: msg.isMe);
  }

  // ── Real SMS message list from Firestore ──────────────────────────────
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
              final isSuspicious = data['isSuspicious'] ?? false;
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
                needsRescan: data['needsRescan'] == true,
              );

              return RepaintBoundary(
                child: Column(
                  crossAxisAlignment: isOutgoing
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    GestureDetector(
                      onLongPress: () => showLocalMessageOptions(msg),
                      child: buildMessageContent(msg),
                    ),
                    buildSuspiciousWarningCard(
                        isSuspicious: isSuspicious, isMe: isOutgoing),
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
                          if (isSuspicious) ...[
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
    DecryptedConversationMessage? projection,
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
    Widget? customContent,
  }) {
    final docPath = doc.reference.path;
    final e2eeIndicator = _buildE2eeIndicatorText(
      data,
      projection,
      isMe: isMe,
    );

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
        isSuspicious: suspicious,
        type: type,
        filePath: null,
      );
    } else if (type == 'file') {
      tempMessage = MessageModel(
        text: fileName.isNotEmpty ? fileName : resolvedText,
        isMe: isMe,
        time: time,
        isSuspicious: suspicious,
        type: type,
        filePath: resolvedText,
      );
    } else {
      tempMessage = MessageModel(
        text: resolvedText,
        isMe: isMe,
        time: time,
        isSuspicious: suspicious,
        type: type,
      );
    }

    final onlineMsgMap = {
      'text': type == 'text' ? resolvedText : '',
      'isMe': isMe,
      'time': formatTime(time),
      'isSuspicious': suspicious,
      'type': type,
      'docPath': docPath,
      'messageId': doc.id,
      'editCount': editCount,
      'isDeleted': isDeleted,
    };

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment:
            isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: isDeleted || isCallSummary
                ? null
                : () => showOnlineMessageOptions(onlineMsgMap),
            child: customContent ?? buildMessageContent(tempMessage),
          ),
          if (!isDeleted && !isCallSummary)
            buildSuspiciousWarningCard(
              isSuspicious: suspicious,
              isMe: isMe,
            ),
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 10, bottom: 6),
            child: Column(
              crossAxisAlignment:
                  isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                if (e2eeIndicator != null &&
                    e2eeIndicator.trim().isNotEmpty &&
                    !isCallSummary)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      e2eeIndicator,
                      style: TextStyle(
                        fontSize: 10,
                        color: isMe ? Colors.white60 : Colors.grey.shade500,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
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
                    if (suspicious && !isDeleted && !isCallSummary) ...[
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

  Widget _buildCachedProjectionList(
    List<DecryptedConversationMessage> projections,
  ) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleMessageScrollNotification,
      child: ListView.builder(
        key: PageStorageKey<String>('online_cached_thread_$otherUserId'),
        controller: _messageScrollController,
        reverse: true,
        physics: const ClampingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        cacheExtent: 460,
        padding: const EdgeInsets.all(10),
        itemCount: projections.length,
        itemBuilder: (context, index) {
          final projection = projections[index];
          return RepaintBoundary(
            child: _buildCachedProjectionTile(projection),
          );
        },
      ),
    );
  }

  Widget _buildCachedProjectionTile(DecryptedConversationMessage projection) {
    final rawText = projection.decryptedText?.trim().isNotEmpty == true
        ? projection.decryptedText!.trim()
        : projection.previewText.trim();
    final displayText = rawText.isNotEmpty
        ? rawText
        : _cachedProjectionFallbackLabel(projection.messageType);
    final displayType = switch (projection.messageType) {
      'deleted' => 'deleted',
      'call_summary' => 'call_summary',
      _ => 'text',
    };
    final message = MessageModel(
      text: displayText,
      isMe: projection.isOutgoing,
      time: projection.timestamp,
      isSuspicious: projection.isSuspicious,
      type: displayType,
    );
    final e2eeIndicator = _buildE2eeIndicatorText(
      <String, dynamic>{
        'e2ee': projection.cipherTextPresent,
        'cipherText': projection.cipherTextPresent ? 'cached' : '',
        'e2eeAlgorithm': projection.algorithm,
      },
      projection,
      isMe: projection.isOutgoing,
    );

    return Column(
      crossAxisAlignment: projection.isOutgoing
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        buildMessageContent(message),
        if (!projection.isDeleted && projection.messageType != 'call_summary')
          buildSuspiciousWarningCard(
            isSuspicious: projection.isSuspicious,
            isMe: projection.isOutgoing,
          ),
        Padding(
          padding: const EdgeInsets.only(left: 10, right: 10, bottom: 6),
          child: Column(
            crossAxisAlignment: projection.isOutgoing
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              if (e2eeIndicator != null && e2eeIndicator.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    e2eeIndicator,
                    style: TextStyle(
                      fontSize: 10,
                      color: projection.isOutgoing
                          ? Colors.white60
                          : Colors.grey.shade500,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatTime(projection.timestamp),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  if (projection.isSuspicious &&
                      !projection.isDeleted &&
                      projection.messageType != 'call_summary') ...[
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 14,
                      color: Colors.orange,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _cachedProjectionFallbackLabel(String messageType) {
    switch (messageType) {
      case 'image':
        return 'Photo';
      case 'gif':
        return 'GIF';
      case 'file':
        return 'File';
      case 'call_summary':
        return 'Call';
      case 'deleted':
        return 'Message deleted';
      default:
        return 'Encrypted message';
    }
  }

  bool _isEncryptedMediaMessage(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    return data['e2eeMedia'] == true &&
        (type == 'image' || type == 'gif' || type == 'file') &&
        (data['text']?.toString().isNotEmpty ?? false);
  }

  bool _isDecryptFailureCoolingDown(
    Map<String, DateTime> failures,
    String cacheKey,
  ) {
    final failedAt = failures[cacheKey];
    if (failedAt == null) {
      return false;
    }
    if (DateTime.now().difference(failedAt) >= _decryptFailureCooldown) {
      failures.remove(cacheKey);
      return false;
    }
    return true;
  }

  Future<void> _acquireDecryptSlot({required bool media}) {
    final limit =
        media ? _maxConcurrentMediaDecrypts : _maxConcurrentTextDecrypts;
    final active = media ? _activeMediaDecrypts : _activeTextDecrypts;
    if (active < limit) {
      if (media) {
        _activeMediaDecrypts++;
      } else {
        _activeTextDecrypts++;
      }
      return Future<void>.value();
    }

    final completer = Completer<void>();
    if (media) {
      _mediaDecryptWaiters.addLast(completer);
    } else {
      _textDecryptWaiters.addLast(completer);
    }
    return completer.future;
  }

  void _releaseDecryptSlot({required bool media}) {
    final queue = media ? _mediaDecryptWaiters : _textDecryptWaiters;
    if (queue.isNotEmpty) {
      queue.removeFirst().complete();
      return;
    }

    if (media) {
      if (_activeMediaDecrypts > 0) {
        _activeMediaDecrypts--;
      }
    } else {
      if (_activeTextDecrypts > 0) {
        _activeTextDecrypts--;
      }
    }
  }

  Future<T> _runWithDecryptSlot<T>({
    required bool media,
    required Future<T> Function() action,
  }) async {
    await _acquireDecryptSlot(media: media);
    try {
      return await action();
    } finally {
      _releaseDecryptSlot(media: media);
    }
  }

  Future<Uint8List> _loadEncryptedMediaBytes(
    String messageId,
    Map<String, dynamic> data,
  ) {
    final cacheKey = data['e2eeCacheKey']?.toString().trim().isNotEmpty == true
        ? data['e2eeCacheKey'].toString().trim()
        : [
            messageId,
            data['e2eeNonce']?.toString() ?? '',
            data['e2eeMac']?.toString() ?? '',
          ].join('|');
    final clientMessageId = data['clientMessageId']?.toString().trim();
    final senderId = data['senderId']?.toString().trim() ?? '';
    final receiverId = data['receiverId']?.toString().trim() ?? '';
    final messageType =
        (data['type'] ?? data['messageType'] ?? 'file').toString().trim();
    final fileName = data['fileName']?.toString();

    if (_isDecryptFailureCoolingDown(_encryptedMediaFailureAt, cacheKey)) {
      return Future<Uint8List>.error(
        Exception('Encrypted media unavailable.'),
      );
    }

    return _encryptedMediaFutures.putIfAbsent(cacheKey, () async {
      try {
        final cachedBytes = await _e2eeService.getCachedMediaBytes(
          cacheKey: cacheKey,
          clientMessageId: clientMessageId,
          messageId: messageId,
          fileName: fileName,
        );
        if (cachedBytes != null && cachedBytes.isNotEmpty) {
          _encryptedMediaFailureAt.remove(cacheKey);
          return cachedBytes;
        }

        if (senderId == currentUserId) {
          throw Exception('Encrypted media unavailable on this device.');
        }

        final url = data['text']?.toString() ?? '';
        if (url.isEmpty) {
          throw Exception('Encrypted media URL missing.');
        }

        final response = await http.get(Uri.parse(url));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception('Failed to download encrypted media.');
        }

        final shouldRetry = _shouldRetryEncryptedDecrypt(data);
        final decryptedBytes = await _runWithDecryptSlot(
          media: true,
          action: () async {
            try {
              return await _e2eeService.decryptBytesMessage(
                data: data,
                cipherBytes: response.bodyBytes,
                allowRepair: false,
              );
            } catch (_) {
              if (!shouldRetry) {
                rethrow;
              }
              await Future<void>.delayed(const Duration(milliseconds: 700));
              return _e2eeService.decryptBytesMessage(
                data: Map<String, dynamic>.from(data),
                cipherBytes: response.bodyBytes,
                allowRepair: true,
              );
            }
          },
        );
        try {
          await _e2eeService.cacheIncomingMediaBytes(
            senderId: senderId,
            receiverId: receiverId,
            bytes: decryptedBytes,
            messageId: messageId,
            clientMessageId: clientMessageId,
            cacheKey: cacheKey,
            messageType: messageType,
            fileName: fileName,
          );
        } catch (error) {
          debugPrint(
              '[ChatScreen] Failed to persist incoming encrypted media: $error');
        }
        _encryptedMediaFailureAt.remove(cacheKey);
        return decryptedBytes;
      } catch (_) {
        _encryptedMediaFailureAt[cacheKey] = DateTime.now();
        _encryptedMediaFutures.remove(cacheKey);
        rethrow;
      }
    });
  }

  // ignore: unused_element
  Future<String> _loadDecryptedText(
    String messageId,
    Map<String, dynamic> data,
  ) {
    final legacyText = data['text']?.toString() ?? '';
    if (!_e2eeService.isEncryptedTextMessage(data)) {
      return Future<String>.value(legacyText);
    }

    final seededText = _e2eeService.getSeededDecryptedText(data);
    if (seededText != null && seededText.trim().isNotEmpty) {
      return Future<String>.value(seededText);
    }

    final cacheKey = data['e2eeCacheKey']?.toString().trim().isNotEmpty == true
        ? data['e2eeCacheKey'].toString().trim()
        : [
            messageId,
            data['e2eeNonce']?.toString() ?? '',
            data['e2eeMac']?.toString() ?? '',
          ].join('|');

    if (_isDecryptFailureCoolingDown(_decryptedTextFailureAt, cacheKey)) {
      return Future<String>.value(
        legacyText.isNotEmpty ? legacyText : '[Encrypted message unavailable]',
      );
    }

    return _decryptedTextFutures.putIfAbsent(cacheKey, () async {
      try {
        final shouldRetry = _shouldRetryEncryptedDecrypt(data);
        final decrypted = await _runWithDecryptSlot(
          media: false,
          action: () async {
            final decryptInput = Map<String, dynamic>.from(data);
            var resolved = await _e2eeService
                .decryptTextMessage(
                  decryptInput,
                  allowRepair: false,
                )
                .timeout(
                  const Duration(seconds: 8),
                  onTimeout: () => legacyText.isNotEmpty
                      ? legacyText
                      : '[Encrypted message unavailable]',
                );
            if (_e2eeService.isUnavailablePlaceholder(resolved) &&
                shouldRetry) {
              await Future<void>.delayed(const Duration(milliseconds: 700));
              resolved = await _e2eeService
                  .decryptTextMessage(
                    Map<String, dynamic>.from(data),
                    allowRepair: true,
                  )
                  .timeout(
                    const Duration(seconds: 6),
                    onTimeout: () => legacyText.isNotEmpty
                        ? legacyText
                        : '[Encrypted message unavailable]',
                  );
            }
            return resolved;
          },
        );
        if (_e2eeService.isUnavailablePlaceholder(decrypted)) {
          _decryptedTextFailureAt[cacheKey] = DateTime.now();
          _decryptedTextFutures.remove(cacheKey);
        } else {
          _decryptedTextFailureAt.remove(cacheKey);
        }
        return decrypted;
      } catch (_) {
        _decryptedTextFailureAt[cacheKey] = DateTime.now();
        _decryptedTextFutures.remove(cacheKey);
        rethrow;
      }
    });
  }

  bool _shouldRetryEncryptedDecrypt(Map<String, dynamic> data) {
    final timestamp = extractFirestoreTime(data['timestamp']);
    final now = DateTime.now();
    final age = now.isAfter(timestamp)
        ? now.difference(timestamp)
        : timestamp.difference(now);
    return age <= const Duration(hours: 1);
  }

  DecryptedConversationMessage? _resolveConversationProjection(
    String messageId,
    Map<String, dynamic> data,
    Map<String, DecryptedConversationMessage> projectionsByMessageId,
    Map<String, DecryptedConversationMessage> projectionsByClientMessageId,
    Map<String, DecryptedConversationMessage> projectionsByCacheKey,
  ) {
    final byMessageId = projectionsByMessageId[messageId];
    if (byMessageId != null) return byMessageId;

    final clientMessageId = data['clientMessageId']?.toString().trim() ?? '';
    if (clientMessageId.isNotEmpty) {
      final byClientMessageId = projectionsByClientMessageId[clientMessageId];
      if (byClientMessageId != null) return byClientMessageId;
    }

    final cacheKey = data['e2eeCacheKey']?.toString().trim() ?? '';
    if (cacheKey.isNotEmpty) {
      return projectionsByCacheKey[cacheKey];
    }

    return null;
  }

  String? _resolvedEncryptedThreadText(
    Map<String, dynamic> data,
    DecryptedConversationMessage? projection,
  ) {
    if (projection != null) {
      switch (projection.decryptionStatus) {
        case ConversationDecryptionStatus.success:
          final text = projection.decryptedText?.trim() ?? '';
          if (text.isNotEmpty) {
            return text;
          }
          break;
        case ConversationDecryptionStatus.failed:
          return projection.failureReason?.trim().isNotEmpty == true
              ? projection.failureReason!.trim()
              : 'Unable to decrypt message';
        case ConversationDecryptionStatus.pending:
          return null;
      }
    }

    final seededText = _e2eeService.getSeededDecryptedText(data);
    if (seededText != null && seededText.trim().isNotEmpty) {
      return seededText;
    }

    return null;
  }

  String? _buildE2eeIndicatorText(
    Map<String, dynamic> data,
    DecryptedConversationMessage? projection, {
    required bool isMe,
  }) {
    final looksEncrypted = data['e2ee'] == true ||
        data['e2eeMedia'] == true ||
        projection?.cipherTextPresent == true ||
        (data['cipherText']?.toString().trim().isNotEmpty ?? false);
    if (!looksEncrypted) {
      return null;
    }

    final projectionAlgorithm = projection?.algorithm?.trim() ?? '';
    final dataAlgorithm = data['e2eeAlgorithm']?.toString().trim() ?? '';
    final algorithm =
        projectionAlgorithm.isNotEmpty ? projectionAlgorithm : dataAlgorithm;
    if (algorithm.isEmpty) {
      return isMe ? 'Sent: E2EE' : 'Received: E2EE';
    }

    final version = (data['e2eeProtocolVersion'] as num?)?.toInt() ??
        (data['e2eeVersion'] as num?)?.toInt() ??
        _extractVersionFromAlgorithm(algorithm);
    final label = _friendlyE2eeLabel(algorithm: algorithm, version: version);
    return isMe ? 'Sent: $label' : 'Received: $label';
  }

  int _extractVersionFromAlgorithm(String algorithm) {
    final match = RegExp(r'v(\d+)$').firstMatch(algorithm.trim());
    if (match == null) {
      return 0;
    }
    return int.tryParse(match.group(1) ?? '') ?? 0;
  }

  String _friendlyE2eeLabel({
    required String algorithm,
    required int version,
  }) {
    final normalized = algorithm.trim().toLowerCase();
    if (normalized == 'signal-v2') {
      return version > 0 ? 'Signal v$version' : 'Signal';
    }
    if (normalized == 'x25519-aesgcm-v1') {
      return version > 0
          ? 'Legacy X25519/AES-GCM v$version'
          : 'Legacy X25519/AES-GCM';
    }
    if (version > 0 && !normalized.endsWith('v$version')) {
      return '$algorithm v$version';
    }
    return algorithm;
  }

  Widget _buildDecryptingBubble({
    required bool isMe,
    required DateTime time,
    String? e2eeIndicator,
  }) {
    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: _surfaceElevatedColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _outlineColor),
          ),
          child: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF25D366)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 10, right: 10, bottom: 6),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (e2eeIndicator != null && e2eeIndicator.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    e2eeIndicator,
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white54,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              Text(
                formatTime(time),
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openEncryptedImagePreviewBytes(Uint8List bytes) async {
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
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openEncryptedFile(
    Uint8List bytes, {
    required String fileName,
  }) async {
    final safeName = fileName.trim().isEmpty ? 'encrypted_file' : fileName;
    final tempDir = await Directory.systemTemp.createTemp('smishing_file_');
    final tempFile = File('${tempDir.path}${Platform.pathSeparator}$safeName');
    await tempFile.writeAsBytes(bytes, flush: true);

    final result = await OpenFilex.open(tempFile.path);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open decrypted file.')),
      );
    }
  }

  Widget _buildEncryptedMediaContent({
    required String messageId,
    required Map<String, dynamic> data,
    required bool isMe,
    required bool suspicious,
    required String type,
    required String fileName,
  }) {
    return FutureBuilder<Uint8List>(
      future: _loadEncryptedMediaBytes(messageId, data),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
              maxHeight: 180,
            ),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: isMe ? const Color(0xFFDCF8C6) : Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              'Encrypted media unavailable',
              style: TextStyle(color: Colors.grey),
            ),
          );
        }

        final bytes = snapshot.data!;
        if (type == 'image' || type == 'gif') {
          return GestureDetector(
            onTap: suspicious
                ? null
                : () => _openEncryptedImagePreviewBytes(bytes),
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
                maxHeight: 260,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => Container(
                    width: 200,
                    height: 120,
                    color: Colors.grey.shade200,
                    child: const Icon(Icons.broken_image_outlined),
                  ),
                ),
              ),
            ),
          );
        }

        return GestureDetector(
          onTap: () => _openEncryptedFile(
            bytes,
            fileName: fileName,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isMe ? const Color(0xFFDCF8C6) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.lock_outline,
                  color: Color(0xFF075E54),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fileName.isNotEmpty ? fileName : 'Encrypted file',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF075E54),
                        ),
                      ),
                      const Text(
                        'Tap to open decrypted file',
                        style: TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget buildOnlineMessageList() {
    return StreamBuilder<List<DecryptedConversationMessage>>(
      stream: _chatEncryptionRepository.watchConversation(
        otherUserId: otherUserId,
      ),
      initialData: const <DecryptedConversationMessage>[],
      builder: (context, projectionSnapshot) {
        final projections =
            projectionSnapshot.data ?? const <DecryptedConversationMessage>[];
        final projectionLookups = _resolveProjectionLookups(projections);

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: _onlineMessagesStream,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              if (projections.isNotEmpty) {
                return _buildCachedProjectionList(projections);
              }
              return const Center(child: Text('Failed to load messages'));
            }
            if (!snapshot.hasData) {
              if (projections.isNotEmpty) {
                return _buildCachedProjectionList(projections);
              }
              return const Center(child: CircularProgressIndicator());
            }

            final docs = _resolveOnlineDocs(snapshot.data!);
            if (docs.isEmpty && projections.isNotEmpty) {
              return _buildCachedProjectionList(projections);
            }

            if (docs.isNotEmpty) {
              _scheduleScrollToLatest(docs.first.id, messageCount: docs.length);
            }

            _scheduleConversationSnapshotSync(
              docs: docs,
              docChanges: snapshot.data!.docChanges,
            );

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
                  final projection = _resolveConversationProjection(
                    doc.id,
                    data,
                    projectionLookups.byMessageId,
                    projectionLookups.byClientMessageId,
                    projectionLookups.byCacheKey,
                  );
                  final isMe = data['senderId'] == currentUserId;
                  final text = data['text']?.toString() ?? '';
                  final suspicious = data['isSuspicious'] ?? false;
                  final type = (data['type'] ?? data['messageType'] ?? 'text')
                      .toString();
                  final isCallSummary = type == 'call_summary';
                  final time = _extractBestMessageTime(data);
                  final fileName = data['fileName'] as String? ?? '';
                  final editCount = data['editCount'] as int? ?? 0;
                  final hasPendingWrites = doc.metadata.hasPendingWrites;
                  final isEdited = editCount > 0;
                  final isDeleted =
                      data['isDeleted'] == true || type == 'deleted';
                  final isEncryptedText = !isDeleted &&
                      _looksEncryptedTextMessage(data, projection);
                  final isEncryptedMedia =
                      !isDeleted && _isEncryptedMediaMessage(data);
                  final resolvedText = isEncryptedText
                      ? _resolvedEncryptedThreadText(data, projection)
                      : text;
                  final isDecrypting = isEncryptedText && resolvedText == null;

                  if (isDecrypting) {
                    final e2eeIndicator = _buildE2eeIndicatorText(
                      data,
                      projection,
                      isMe: isMe,
                    );
                    return RepaintBoundary(
                      child: _buildDecryptingBubble(
                        isMe: isMe,
                        time: time,
                        e2eeIndicator: e2eeIndicator,
                      ),
                    );
                  }

                  if (isEncryptedMedia) {
                    return RepaintBoundary(
                      child: _buildOnlineMessageTile(
                        data: data,
                        doc: doc,
                        projection: projection,
                        isMe: isMe,
                        resolvedText: resolvedText ?? '',
                        suspicious: suspicious,
                        type: type,
                        isCallSummary: isCallSummary,
                        time: time,
                        fileName: fileName,
                        editCount: editCount,
                        isEdited: isEdited,
                        isDeleted: isDeleted,
                        hasPendingWrites: hasPendingWrites,
                        customContent: _buildEncryptedMediaContent(
                          messageId: doc.id,
                          data: Map<String, dynamic>.from(data),
                          isMe: isMe,
                          suspicious: suspicious,
                          type: type,
                          fileName: fileName,
                        ),
                      ),
                    );
                  }

                  return RepaintBoundary(
                    child: _buildOnlineMessageTile(
                      data: data,
                      doc: doc,
                      projection: projection,
                      isMe: isMe,
                      resolvedText: resolvedText ?? '',
                      suspicious: suspicious,
                      type: type,
                      isCallSummary: isCallSummary,
                      time: time,
                      fileName: fileName,
                      editCount: editCount,
                      isEdited: isEdited,
                      isDeleted: isDeleted,
                      hasPendingWrites: hasPendingWrites,
                    ),
                  );
                },
              ),
            );
              },
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
            _buildModeBanner(isSms: isSms),
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

class _ConversationProjectionLookups {
  final Map<String, DecryptedConversationMessage> byMessageId;
  final Map<String, DecryptedConversationMessage> byClientMessageId;
  final Map<String, DecryptedConversationMessage> byCacheKey;

  const _ConversationProjectionLookups({
    required this.byMessageId,
    required this.byClientMessageId,
    required this.byCacheKey,
  });

  const _ConversationProjectionLookups.empty()
      : byMessageId = const <String, DecryptedConversationMessage>{},
        byClientMessageId = const <String, DecryptedConversationMessage>{},
        byCacheKey = const <String, DecryptedConversationMessage>{};
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
                final opacity =
                    (0.3 + 0.7 * (0.5 + 0.5 * sin(phase * 2 * pi)))
                        .clamp(0.0, 1.0);
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Opacity(
                    opacity: opacity,
                    child: const Text(
                      '•',
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
