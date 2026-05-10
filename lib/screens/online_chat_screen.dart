import 'dart:async';
import 'dart:collection';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../services/chat/contact_chat_service.dart';
import '../services/chat/online_chat_service.dart';
import '../services/auth/user_profile_service.dart';
import '../widgets/user_avatar.dart';
import 'chat_screen.dart';
import 'friends_management_screen.dart';
import 'new_online_message_screen.dart';

class OnlineChatScreen extends StatefulWidget {
  const OnlineChatScreen({super.key});

  @override
  State<OnlineChatScreen> createState() => _OnlineChatScreenState();
}

class _OnlineChatScreenState extends State<OnlineChatScreen> {
  final TextEditingController searchController = TextEditingController();
  final OnlineChatService onlineChatService = OnlineChatService();
  final ContactChatService contactChatService = ContactChatService();
  final LinkedHashMap<String, StreamSubscription<DocumentSnapshot>>
      _presenceSubscriptions =
      LinkedHashMap<String, StreamSubscription<DocumentSnapshot>>();
  final Map<String, ValueNotifier<Map<String, dynamic>?>> _presenceNotifiers =
      <String, ValueNotifier<Map<String, dynamic>?>>{};

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _chatSubscription;
  StreamSubscription<QuerySnapshot>? _friendsSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
      _settingsSubscription;
  QuerySnapshot<Map<String, dynamic>>? _chatSnapshot;
  QuerySnapshot? _friendsSnapshot;
  QuerySnapshot<Map<String, dynamic>>? _settingsSnapshot;
  Object? _chatLoadError;
  Object? _friendsLoadError;
  int _chatVersion = 0;
  int _friendsVersion = 0;
  int _settingsVersion = 0;
  String? _mergedEntriesCacheKey;
  String? _legacyConversationRepairKey;
  List<_ConversationEntry> _mergedEntriesCache = const <_ConversationEntry>[];
  Timer? _searchDebounceTimer;
  Timer? _connectionBannerTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool? _hasInternetConnection;
  bool _showConnectedBanner = false;
  bool _connectivityInitialized = false;
  bool _hadConnectivityOutage = false;

  String searchText = '';
  static const Duration _searchDebounceDuration = Duration(milliseconds: 120);
  static const int _maxInboxPresenceSubscriptions = 12;
  static const Color _bgColor = Color(0xFF0B1622);
  static const Color _surfaceColor = Color(0xFF101C2B);
  static const Color _surfaceElevatedColor = Color(0xFF162334);
  static const Color _inputFillColor = Color(0xFF1A2737);
  static const Color _accentColor = Color(0xFF25D366);
  static const Color _headerColor = Color(0xFF0E1A28);
  static const Color _textPrimary = Color(0xFFF5FAFF);
  static const Color _textMuted = Color(0xFF93A4B5);

  @override
  void initState() {
    super.initState();
    searchController.addListener(_handleSearchChanged);
    unawaited(onlineChatService.scheduleConversationActivityBackfillIfNeeded());
    _startInboxSubscriptions();
    _startConnectivityMonitor();
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

  @override
  void dispose() {
    searchController.removeListener(_handleSearchChanged);
    _searchDebounceTimer?.cancel();
    _connectionBannerTimer?.cancel();
    _connectivitySubscription?.cancel();
    _chatSubscription?.cancel();
    _friendsSubscription?.cancel();
    _settingsSubscription?.cancel();
    for (final subscription in _presenceSubscriptions.values) {
      subscription.cancel();
    }
    for (final notifier in _presenceNotifiers.values) {
      notifier.dispose();
    }
    searchController.dispose();
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
      debugPrint('[OnlineChatScreen] Connectivity check failed: $error');
    }
  }

  void _setInitialConnectivityState(List<ConnectivityResult> results) {
    if (!mounted) return;
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
    if (!mounted) return;

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

  void _handleSearchChanged() {
    final nextValue = searchController.text;
    if (nextValue == searchText) {
      return;
    }
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(_searchDebounceDuration, () {
      if (!mounted) return;
      setState(() {
        searchText = nextValue;
      });
    });
  }

  void _startInboxSubscriptions() {
    _chatSubscription = onlineChatService.getUserChats().listen(
      (snapshot) {
        if (!mounted) return;
        setState(() {
          _chatSnapshot = snapshot;
          _chatLoadError = null;
          _chatVersion++;
        });
      },
      onError: (Object error) {
        debugPrint('[OnlineChatScreen] chat stream error: $error');
        if (!mounted) return;
        setState(() {
          _chatLoadError = error;
        });
      },
    );

    _friendsSubscription = contactChatService.getMyContacts().listen(
      (snapshot) {
        if (!mounted) return;
        setState(() {
          _friendsSnapshot = snapshot;
          _friendsLoadError = null;
          _friendsVersion++;
        });
        unawaited(_repairLegacyConversationSummaries(snapshot));
      },
      onError: (Object error) {
        debugPrint('[OnlineChatScreen] contacts stream error: $error');
        if (!mounted) return;
        setState(() {
          _friendsLoadError = error;
        });
      },
    );

    _settingsSubscription = onlineChatService.getChatSettings().listen(
      (snapshot) {
        if (!mounted) return;
        setState(() {
          _settingsSnapshot = snapshot;
          _settingsVersion++;
        });
      },
      onError: (_) {},
    );
  }

  String _docUid(QueryDocumentSnapshot doc) {
    final rawData = doc.data();
    if (rawData is Map) {
      final uid = rawData['uid']?.toString().trim() ?? '';
      if (uid.isNotEmpty) {
        return uid;
      }
    }
    return doc.id.trim();
  }

  Future<void> _repairLegacyConversationSummaries(
    QuerySnapshot snapshot,
  ) async {
    final friendIds = snapshot.docs
        .map(_docUid)
        .where(
          (uid) => uid.isNotEmpty && uid != onlineChatService.currentUserId,
        )
        .toList(growable: false)
      ..sort();

    if (friendIds.isEmpty) {
      _legacyConversationRepairKey = null;
      return;
    }

    final repairKey = friendIds.join('|');
    if (_legacyConversationRepairKey == repairKey) {
      return;
    }
    _legacyConversationRepairKey = repairKey;

    try {
      await onlineChatService.repairLegacyConversationSummariesForUsers(
        friendIds,
      );
    } catch (error) {
      _legacyConversationRepairKey = null;
      debugPrint(
        '[OnlineChatScreen] legacy conversation repair error: $error',
      );
    }
  }

  ValueNotifier<Map<String, dynamic>?> _presenceNotifierFor(String uid) {
    return _presenceNotifiers.putIfAbsent(
      uid,
      () => ValueNotifier<Map<String, dynamic>?>(null),
    );
  }

  void _trackPresence(String uid) {
    final trimmedUid = uid.trim();
    if (trimmedUid.isEmpty) return;

    final existing = _presenceSubscriptions.remove(trimmedUid);
    if (existing != null) {
      _presenceSubscriptions[trimmedUid] = existing;
      return;
    }

    if (_presenceSubscriptions.length >= _maxInboxPresenceSubscriptions) {
      final evictedUid = _presenceSubscriptions.keys.first;
      _presenceSubscriptions.remove(evictedUid)?.cancel();
    }

    final notifier = _presenceNotifierFor(trimmedUid);
    final subscription = onlineChatService.getUserStatus(trimmedUid).listen(
      (doc) {
        notifier.value =
            doc.exists ? doc.data() as Map<String, dynamic>? : null;
      },
      onError: (_) {},
    );
    _presenceSubscriptions[trimmedUid] = subscription;
  }

  void _openChat({
    required String uid,
    required String name,
  }) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactName: name,
          phone: '',
          chatType: 'online',
          receiverId: uid,
        ),
      ),
    );
  }

  Future<void> _deleteConversation({
    required String uid,
    required String name,
  }) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete Conversation?'),
            content: Text(
                'Delete your chat with $name? The messages will be removed from your device, but the other person can still see them.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style:
                    ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirmed) return;

    try {
      final chatId = onlineChatService.getChatId(uid);
      final chatRef =
          FirebaseFirestore.instance.collection('chats').doc(chatId);
      final currentUserId = onlineChatService.currentUserId;

      // 1. Hide conversation from the active list
      await onlineChatService.hideConversation(uid);

      // 2. Mark all existing messages as deleted for the current user only
      final messages = await chatRef.collection('messages').get();
      if (messages.docs.isNotEmpty) {
        final batch = FirebaseFirestore.instance.batch();
        for (final doc in messages.docs) {
          batch.set(
            doc.reference,
            {
              'deletedFor': FieldValue.arrayUnion([currentUserId])
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Conversation with $name deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete conversation: $e')),
      );
    }
  }

  Future<void> _toggleConversationMute({
    required _ConversationEntry entry,
    required bool muted,
  }) async {
    await onlineChatService.setConversationMuted(
      otherUserId: entry.uid,
      muted: muted,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          muted
              ? 'Notifications muted for ${entry.name}'
              : 'Notifications unmuted for ${entry.name}',
        ),
      ),
    );
  }

  Future<void> _toggleConversationBlock({
    required _ConversationEntry entry,
    required bool blocked,
  }) async {
    if (blocked) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text('Block ${entry.name}?'),
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
    }

    await onlineChatService.setConversationBlocked(
      otherUserId: entry.uid,
      blocked: blocked,
      otherName: entry.name,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          blocked ? '${entry.name} blocked' : '${entry.name} unblocked',
        ),
      ),
    );
  }

  Future<void> _toggleConversationReadState({
    required _ConversationEntry entry,
    required bool unread,
  }) async {
    if (unread) {
      await onlineChatService.markConversationUnread(entry.uid);
    } else {
      await onlineChatService.markMessagesAsRead(entry.uid);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          unread
              ? 'Marked ${entry.name} as unread'
              : 'Marked ${entry.name} as read',
        ),
      ),
    );
  }

  Future<void> _showConversationActions({
    required _ConversationEntry entry,
    required bool isMuted,
    required bool isBlocked,
    required bool isUnread,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          top: false,
          child: Wrap(
            children: [
              ListTile(
                leading:
                    const Icon(Icons.chat_bubble_outline, color: Colors.white),
                title: const Text('Open chat',
                    style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openChat(uid: entry.uid, name: entry.name);
                },
              ),
              ListTile(
                leading: Icon(
                  isUnread
                      ? Icons.mark_chat_read_outlined
                      : Icons.mark_chat_unread_outlined,
                  color: isUnread ? Colors.white70 : _accentColor,
                ),
                title: Text(
                  isUnread ? 'Mark as read' : 'Mark as unread',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleConversationReadState(
                    entry: entry,
                    unread: !isUnread,
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  isMuted
                      ? Icons.notifications_active_outlined
                      : Icons.notifications_off_outlined,
                  color: isMuted ? Colors.white70 : Colors.orangeAccent,
                ),
                title: Text(
                  isMuted ? 'Unmute notifications' : 'Mute notifications',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleConversationMute(entry: entry, muted: !isMuted);
                },
              ),
              ListTile(
                leading: Icon(
                  isBlocked ? Icons.person_outline : Icons.block,
                  color: isBlocked ? Colors.white70 : Colors.redAccent,
                ),
                title: Text(
                  isBlocked ? 'Unblock user' : 'Block user',
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _toggleConversationBlock(entry: entry, blocked: !isBlocked);
                },
              ),
              if (entry.hasConversation)
                ListTile(
                  leading: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  title: const Text(
                    'Delete chat',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: const Text(
                    'Delete this conversation from your end only',
                    style: TextStyle(color: Colors.white54),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _deleteConversation(uid: entry.uid, name: entry.name);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.close, color: Colors.white54),
                title: const Text('Cancel',
                    style: TextStyle(color: Colors.white70)),
                onTap: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        );
      },
    );
  }

  // ignore: unused_element
  String _formatUpdatedAt(Timestamp? timestamp) {
    if (timestamp == null) return '';
    final dt = timestamp.toDate();
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}/${dt.year.toString().substring(2)}';
  }

  DateTime? _parseDateTime(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) return DateTime.fromMillisecondsSinceEpoch(raw);
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) {
      final parsedInt = int.tryParse(raw);
      if (parsedInt != null) {
        return DateTime.fromMillisecondsSinceEpoch(parsedInt);
      }
      return DateTime.tryParse(raw);
    }
    return null;
  }

  int? _parseInt(dynamic raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  int _activitySortMs({
    required DateTime? lastMessageAt,
    required int? lastMessageAtClientMs,
    required DateTime? updatedAt,
  }) {
    final lastMessageAtMs = lastMessageAt?.millisecondsSinceEpoch ?? 0;
    final clientMs = lastMessageAtClientMs ?? 0;
    final updatedAtMs = updatedAt?.millisecondsSinceEpoch ?? 0;
    var best = lastMessageAtMs;
    if (clientMs > best) best = clientMs;
    if (updatedAtMs > best) best = updatedAtMs;
    return best;
  }

  DateTime? _effectiveActivityAt({
    required DateTime? lastMessageAt,
    required int? lastMessageAtClientMs,
    required DateTime? updatedAt,
  }) {
    final effectiveMs = _activitySortMs(
      lastMessageAt: lastMessageAt,
      lastMessageAtClientMs: lastMessageAtClientMs,
      updatedAt: updatedAt,
    );
    if (effectiveMs <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(effectiveMs);
  }

  List<String> _readStringList(dynamic raw) {
    if (raw is Iterable) {
      return raw
          .map((item) => item?.toString().trim() ?? '')
          .where((item) => item.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  String _formatUpdatedAtDateTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}/${dt.year.toString().substring(2)}';
  }

  List<_ConversationEntry> _resolveMergedEntries({
    required QuerySnapshot<Map<String, dynamic>> chatSnapshot,
    QuerySnapshot? friendSnapshot,
    required bool includeFriendOnlyEntries,
  }) {
    final cacheKey = '$_chatVersion|$_friendsVersion|$_settingsVersion|'
        '${includeFriendOnlyEntries ? 'friends:on' : 'friends:off'}|'
        '${searchText.trim().toLowerCase()}';
    if (_mergedEntriesCacheKey == cacheKey) {
      return _mergedEntriesCache;
    }

    final entries = _mergeEntries(
      chatSnapshot: chatSnapshot,
      friendSnapshot: friendSnapshot,
      includeFriendOnlyEntries: includeFriendOnlyEntries,
    );
    _mergedEntriesCacheKey = cacheKey;
    _mergedEntriesCache = entries;
    return entries;
  }

  Map<String, Map<String, dynamic>> _settingsByUid() {
    final settingsByUid = <String, Map<String, dynamic>>{};
    final snapshot = _settingsSnapshot;
    if (snapshot == null) {
      return settingsByUid;
    }
    for (final doc in snapshot.docs) {
      settingsByUid[doc.id] = doc.data();
    }
    return settingsByUid;
  }

  List<_ConversationEntry> _mergeEntries({
    required QuerySnapshot<Map<String, dynamic>> chatSnapshot,
    QuerySnapshot? friendSnapshot,
    required bool includeFriendOnlyEntries,
  }) {
    final activeEntries = <String, _ConversationEntry>{};
    final friendOnlyEntries = <String, _ConversationEntry>{};
    final hiddenUids = <String>{};
    final query = searchText.trim().toLowerCase();

    for (final doc in chatSnapshot.docs) {
      try {
        final data = doc.data();
        final hiddenFor = Map<String, dynamic>.from(
          data['hiddenFor'] ?? const <String, dynamic>{},
        );

        final participants = _readStringList(data['participants']);
        final otherUserId = participants.firstWhere(
          (uid) => uid != onlineChatService.currentUserId,
          orElse: () => '',
        );
        if (otherUserId.isEmpty) continue;

        if (hiddenFor[onlineChatService.currentUserId] == true) {
          hiddenUids.add(otherUserId);
          continue;
        }

        final names = Map<String, dynamic>.from(
          data['participantNames'] ?? const <String, dynamic>{},
        );
        final otherName =
            (names[otherUserId]?.toString().trim().isNotEmpty == true)
                ? names[otherUserId].toString().trim()
                : 'Unknown User';
        final lastMessage = data['lastMessage']?.toString() ?? '';

        if (query.isNotEmpty &&
            !otherName.toLowerCase().contains(query) &&
            !lastMessage.toLowerCase().contains(query)) {
          continue;
        }

        final lastMessageSenderId =
            data['lastMessageSenderId']?.toString() ?? '';
        final lastMessageIsRead = data['lastMessageIsRead'] == true;
        final lastMessageType = data['lastMessageType']?.toString() ?? 'text';
        final updatedAt = _parseDateTime(data['updatedAt']);
        final lastMessageAt = _effectiveActivityAt(
          lastMessageAt: _parseDateTime(data['lastMessageAt']),
          lastMessageAtClientMs: _parseInt(data['lastMessageAtClientMs']),
          updatedAt: updatedAt,
        );
        final lastMessageAtClientMs = _parseInt(data['lastMessageAtClientMs']);

        String statusLabel = '';
        if (lastMessage.isNotEmpty &&
            lastMessageSenderId == onlineChatService.currentUserId &&
            lastMessageIsRead) {
          statusLabel = 'Seen';
        } else if (lastMessage.isNotEmpty &&
            lastMessageSenderId != onlineChatService.currentUserId &&
            !lastMessageIsRead) {
          statusLabel = 'Unread';
        }

        activeEntries[otherUserId] = _ConversationEntry(
          chatId: doc.id,
          uid: otherUserId,
          name: otherName,
          lastMessage: lastMessage,
          lastMessageType: lastMessageType,
          lastMessageClientMessageId:
              data['lastMessageClientMessageId']?.toString(),
          lastMessageSenderId: lastMessageSenderId,
          lastMessageAt: lastMessageAt,
          lastMessageAtClientMs: lastMessageAtClientMs,
          updatedAt: updatedAt,
          statusLabel: statusLabel,
          hasConversation: true,
        );
      } catch (_) {
        continue;
      }
    }

    if (includeFriendOnlyEntries && friendSnapshot != null) {
      for (final doc in friendSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final uid = _docUid(doc);
        if (uid.isEmpty) continue;
        if (activeEntries.containsKey(uid)) continue;
        if (hiddenUids.contains(uid)) continue;

        final name = (data['name']?.toString().trim().isNotEmpty == true)
            ? data['name'].toString().trim()
            : 'Unknown User';

        if (query.isNotEmpty && !name.toLowerCase().contains(query)) {
          continue;
        }

        friendOnlyEntries[uid] = _ConversationEntry(
          chatId: onlineChatService.getChatId(uid),
          uid: uid,
          name: name,
          lastMessage: '',
          lastMessageType: 'text',
          lastMessageClientMessageId: null,
          lastMessageSenderId: '',
          lastMessageAt: null,
          lastMessageAtClientMs: null,
          updatedAt: null,
          statusLabel: '',
          hasConversation: false,
        );
      }
    }

    final active = activeEntries.values.toList()
      ..sort((a, b) {
        final byActivity = _activitySortMs(
          lastMessageAt: b.lastMessageAt,
          lastMessageAtClientMs: b.lastMessageAtClientMs,
          updatedAt: b.updatedAt,
        ).compareTo(
          _activitySortMs(
            lastMessageAt: a.lastMessageAt,
            lastMessageAtClientMs: a.lastMessageAtClientMs,
            updatedAt: a.updatedAt,
          ),
        );
        if (byActivity != 0) return byActivity;

        final byUpdatedAt =
            (b.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
          a.updatedAt?.millisecondsSinceEpoch ?? 0,
        );
        if (byUpdatedAt != 0) return byUpdatedAt;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    final friendOnly = friendOnlyEntries.values.toList()
      ..sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );

    return <_ConversationEntry>[
      ...active,
      ...friendOnly,
    ];
  }

  Widget _buildPreviewWidget(_ConversationEntry entry, {required bool unread}) {
    return Text(
      _fallbackPreviewText(entry),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: unread ? _textPrimary : _textMuted,
        fontSize: 13,
        fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
      ),
    );
  }

  String _fallbackPreviewText(_ConversationEntry entry) {
    switch (entry.lastMessageType) {
      case 'image':
        return 'Photo';
      case 'gif':
        return 'GIF';
      case 'file':
        return 'File';
      case 'call_summary':
        return entry.lastMessage.isNotEmpty ? entry.lastMessage : 'Call';
      default:
        if (entry.lastMessage.isNotEmpty) {
          return entry.lastMessage;
        }
        return 'Tap to start chatting';
    }
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            _headerColor,
            _surfaceColor,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Online',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                    ),
                    SizedBox(height: 6),
                    Text(
                      'Encrypted chats and synced conversations.',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const FriendsManagementScreen(),
                      ),
                    );
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: _surfaceElevatedColor,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.people_alt_outlined,
                            color: Colors.white, size: 16),
                        SizedBox(width: 6),
                        Text(
                          'Friends',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              color: _inputFillColor,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white10),
            ),
            child: TextField(
              controller: searchController,
              style: const TextStyle(color: Colors.white),
              cursorColor: _accentColor,
              decoration: InputDecoration(
                hintText: 'Search conversations',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                suffixIcon: searchText.trim().isNotEmpty
                    ? IconButton(
                        onPressed: () {
                          _searchDebounceTimer?.cancel();
                          searchController.clear();
                          setState(() => searchText = '');
                        },
                        icon: const Icon(
                          Icons.close,
                          color: Colors.white54,
                          size: 18,
                        ),
                      )
                    : null,
                filled: true,
                fillColor: Colors.transparent,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(18),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          const SizedBox(height: 14),
          const Row(
            children: [
              Text(
                'Recent conversations',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.touch_app_outlined,
                      color: Colors.white38, size: 13),
                  SizedBox(width: 4),
                  Text(
                    'Hold for actions',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionBanner() {
    final bool? connected = _hasInternetConnection;
    if (connected == null ||
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

  Widget _buildStatusChip(String text, {required bool unread}) {
    final bg =
        unread ? _accentColor.withValues(alpha: 0.16) : _surfaceElevatedColor;
    final fg = unread ? _accentColor : Colors.white;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
            color:
                unread ? _accentColor.withValues(alpha: 0.28) : Colors.white10),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: fg,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 92,
            height: 92,
            decoration: BoxDecoration(
              color: _surfaceColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white10),
            ),
            child: const Icon(
              Icons.forum_outlined,
              size: 40,
              color: _accentColor,
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'No conversations yet',
            style: TextStyle(
              color: _textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 6),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 28),
            child: Text(
              'Add a friend or open a contact to start your first online conversation.',
              textAlign: TextAlign.center,
              style: TextStyle(color: _textMuted),
            ),
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: _accentColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NewOnlineMessageScreen(),
                ),
              );
            },
            icon: const Icon(
              Icons.edit_square,
              color: Colors.white,
            ),
            label: const Text(
              'New Message',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWarningBanner(String message) {
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(
              Icons.info_outline,
              color: Colors.amberAccent,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationLoadErrorState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: _surfaceColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white10),
              ),
              child: const Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: Colors.orangeAccent,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Conversations unavailable right now',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _textMuted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactsFallbackState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                color: _surfaceColor,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white10),
              ),
              child: const Icon(
                Icons.forum_outlined,
                size: 40,
                color: _accentColor,
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'No recent conversations yet',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _textMuted,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationList(
    List<_ConversationEntry> entries, {
    required Map<String, Map<String, dynamic>> settingsByUid,
  }) {
    return ListView.separated(
      key: const PageStorageKey<String>('online_conversation_list'),
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      cacheExtent: 900,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 96),
      itemCount: entries.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final updatedAt = _formatUpdatedAtDateTime(
          entry.lastMessageAt ?? entry.updatedAt,
        );
        final settings = settingsByUid[entry.uid] ?? const <String, dynamic>{};
        final isMuted = settings['mutedNotifications'] == true;
        final isBlocked = settings['blocked'] == true;
        final isUnread =
            settings['manualUnread'] == true || entry.statusLabel == 'Unread';

        _trackPresence(entry.uid);
        final presenceNotifier = _presenceNotifierFor(entry.uid);

        return RepaintBoundary(
          child: ValueListenableBuilder<Map<String, dynamic>?>(
            valueListenable: presenceNotifier,
            builder: (context, statusData, _) {
              final isOnline =
                  OnlineChatService.computeEffectiveOnline(statusData);
              final presenceMode = OnlineChatService.normalizePresenceMode(
                statusData?['presenceMode']?.toString(),
              );
              final photoUrl = statusData?['photoUrl']?.toString();
              final resolvedName = UserProfileService.resolveDisplayName(
                data: statusData,
                fallback: entry.name,
              );

              return Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onLongPress: () => _showConversationActions(
                    entry: _ConversationEntry(
                      chatId: entry.chatId,
                      uid: entry.uid,
                      name: resolvedName,
                      lastMessage: entry.lastMessage,
                      lastMessageType: entry.lastMessageType,
                      lastMessageClientMessageId:
                          entry.lastMessageClientMessageId,
                      lastMessageSenderId: entry.lastMessageSenderId,
                      lastMessageAt: entry.lastMessageAt,
                      lastMessageAtClientMs: entry.lastMessageAtClientMs,
                      updatedAt: entry.updatedAt,
                      statusLabel: entry.statusLabel,
                      hasConversation: entry.hasConversation,
                    ),
                    isMuted: isMuted,
                    isBlocked: isBlocked,
                    isUnread: isUnread,
                  ),
                  onTap: () => _openChat(
                    uid: entry.uid,
                    name: resolvedName,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: _surfaceColor,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isBlocked
                            ? Colors.redAccent.withValues(alpha: 0.24)
                            : Colors.white10,
                      ),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 18,
                          offset: Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Stack(
                          children: [
                            UserAvatar(
                              name: resolvedName,
                              imageUrl: photoUrl,
                              radius: 28,
                              backgroundColor: Colors.white12,
                              foregroundColor: Colors.white,
                            ),
                            if (isOnline ||
                                presenceMode == 'dnd' ||
                                presenceMode == 'idle')
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  width: 14,
                                  height: 14,
                                  decoration: BoxDecoration(
                                    color: _presenceColor(
                                      presenceMode,
                                      isOnline,
                                    ),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: _surfaceColor,
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                resolvedName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: _textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 18,
                                ),
                              ),
                              const SizedBox(height: 5),
                              _buildPreviewWidget(
                                entry,
                                unread: isUnread,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (isMuted)
                                  const Padding(
                                    padding: EdgeInsets.only(right: 6),
                                    child: Icon(
                                      Icons.notifications_off_outlined,
                                      color: Colors.white38,
                                      size: 14,
                                    ),
                                  ),
                                if (updatedAt.isNotEmpty)
                                  Text(
                                    updatedAt,
                                    style: const TextStyle(
                                      color: _textMuted,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                            if (isBlocked)
                              _buildStatusChip(
                                'Blocked',
                                unread: false,
                              )
                            else if (isUnread)
                              _buildStatusChip(
                                'Unread',
                                unread: true,
                              )
                            else if (entry.statusLabel == 'Seen')
                              _buildStatusChip(
                                'Seen',
                                unread: false,
                              )
                            else if (!entry.hasConversation)
                              _buildStatusChip(
                                'Friend',
                                unread: false,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildConversationListBody() {
    if (_chatLoadError != null) {
      return _buildConversationLoadErrorState(
        _friendlyInboxError(_chatLoadError!, contacts: false),
      );
    }

    if (_chatSnapshot == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final contactsFailed = _friendsLoadError != null;
    final contactsLoaded = _friendsSnapshot != null && !contactsFailed;
    final contactsStillLoading = _friendsSnapshot == null && !contactsFailed;
    final contactsWarningMessage = contactsFailed
        ? '${_friendlyInboxError(_friendsLoadError!, contacts: true)} Existing conversations still work.'
        : null;

    final entries = _resolveMergedEntries(
      chatSnapshot: _chatSnapshot!,
      friendSnapshot: contactsLoaded ? _friendsSnapshot : null,
      includeFriendOnlyEntries: contactsLoaded,
    );

    if (entries.isEmpty) {
      if (contactsFailed) {
        return Column(
          children: [
            _buildWarningBanner(contactsWarningMessage!),
            Expanded(
              child: _buildContactsFallbackState(
                'Contacts could not be loaded, so only existing conversations can be shown right now.',
              ),
            ),
          ],
        );
      }
      if (contactsStillLoading) {
        return const Center(child: CircularProgressIndicator());
      }
      return _buildEmptyState();
    }

    final settingsByUid = _settingsByUid();
    final list = _buildConversationList(
      entries,
      settingsByUid: settingsByUid,
    );
    if (!contactsFailed) {
      return list;
    }

    return Column(
      children: [
        _buildWarningBanner(contactsWarningMessage!),
        Expanded(child: list),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _headerColor,
        toolbarHeight: 0,
        elevation: 0,
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _accentColor,
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const NewOnlineMessageScreen(),
            ),
          );
        },
        child: const Icon(Icons.edit_square, color: Colors.white),
      ),
      body: Column(
        children: [
          _buildHeader(),
          _buildConnectionBanner(),
          Expanded(
            child: _buildConversationListBody(),
          ),
        ],
      ),
    );
  }
}

class _ConversationEntry {
  final String chatId;
  final String uid;
  final String name;
  final String lastMessage;
  final String lastMessageType;
  final String? lastMessageClientMessageId;
  final String lastMessageSenderId;
  final DateTime? lastMessageAt;
  final int? lastMessageAtClientMs;
  final DateTime? updatedAt;
  final String statusLabel;
  final bool hasConversation;

  const _ConversationEntry({
    required this.chatId,
    required this.uid,
    required this.name,
    required this.lastMessage,
    required this.lastMessageType,
    this.lastMessageClientMessageId,
    this.lastMessageSenderId = '',
    required this.lastMessageAt,
    required this.lastMessageAtClientMs,
    required this.updatedAt,
    required this.statusLabel,
    required this.hasConversation,
  });
}

String _friendlyInboxError(
  Object error, {
  required bool contacts,
}) {
  final subject = contacts ? 'Contacts' : 'Conversations';
  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return '$subject are unavailable for this account right now.';
      case 'unavailable':
        return '$subject are temporarily unavailable. Check your connection and try again.';
      case 'failed-precondition':
        return '$subject are unavailable right now. Please try again later.';
      default:
        return '$subject are unavailable right now.';
    }
  }
  return '$subject are unavailable right now.';
}
