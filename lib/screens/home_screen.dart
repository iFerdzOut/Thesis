import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/chat_notification_service.dart';
import '../services/friend_request_notification_service.dart';
import '../services/online_chat_service.dart';
import 'dashboard_screen.dart';
import 'online_auth_prompt_screen.dart';
import 'online_chat_screen.dart';
import 'phone_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final bool hasSession;
  final bool hasOnlineAccess;

  const HomeScreen({
    super.key,
    required this.hasSession,
    required this.hasOnlineAccess,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const String _initialPermissionsKey =
      'initial_permissions_setup_done_v1';
  static const Duration _presenceHeartbeatInterval = Duration(seconds: 45);
  static const Duration _presenceWriteCooldown = Duration(seconds: 30);

  int currentIndex = 0;

  final OnlineChatService _chatService = OnlineChatService();

  bool _resumeCheckPending = false;
  bool _permissionsRequested = false;
  bool _realtimeServicesStarted = false;
  Timer? _presenceHeartbeatTimer;
  DateTime? _lastPresenceWriteAt;
  late List<Widget?> _pageCache;
  final Set<int> _initializedPageIndexes = <int>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetPageCache();
    _applyOnlineServiceState(enabled: widget.hasOnlineAccess);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _runInitialPermissionSetup();
    });
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.hasOnlineAccess != widget.hasOnlineAccess) {
      _resetPageCache();
      _applyOnlineServiceState(enabled: widget.hasOnlineAccess);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceHeartbeatTimer?.cancel();
    _applyOnlineServiceState(enabled: false);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (widget.hasOnlineAccess) {
        _setOnlineIfNeeded(force: true);
        _startRealtimeServicesIfNeeded();
      }
      if (!_resumeCheckPending) {
        _resumeCheckPending = true;
        Future.delayed(const Duration(milliseconds: 1000), () {
          _resumeCheckPending = false;
        });
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (widget.hasOnlineAccess) {
        unawaited(_setOfflineSafely());
      }
    } else if (state == AppLifecycleState.detached) {
      _applyOnlineServiceState(enabled: false);
    }
  }

  void _applyOnlineServiceState({required bool enabled}) {
    if (enabled) {
      _setOnlineIfNeeded(force: true);
      _presenceHeartbeatTimer?.cancel();
      _presenceHeartbeatTimer = Timer.periodic(
        _presenceHeartbeatInterval,
        (_) {
          if (!mounted || !widget.hasOnlineAccess) return;
          _setOnlineIfNeeded();
        },
      );
      _startRealtimeServicesIfNeeded();
    } else {
      _presenceHeartbeatTimer?.cancel();
      _presenceHeartbeatTimer = null;
      unawaited(_stopRealtimeServices());
      unawaited(_setOfflineSafely());
    }
  }

  void _setOnlineIfNeeded({bool force = false}) {
    final now = DateTime.now();
    if (!force &&
        _lastPresenceWriteAt != null &&
        now.difference(_lastPresenceWriteAt!) < _presenceWriteCooldown) {
      return;
    }
    _lastPresenceWriteAt = now;
    unawaited(_chatService.setOnline());
  }

  void _resetPageCache() {
    _pageCache = List<Widget?>.filled(4, null, growable: false);
    _initializedPageIndexes
      ..clear()
      ..add(currentIndex);
    _ensurePageInitialized(currentIndex);
  }

  void _ensurePageInitialized(int index) {
    if (index < 0 || index >= _pageCache.length) return;
    _initializedPageIndexes.add(index);
    _pageCache[index] ??= _buildPageForIndex(index);
  }

  Widget _buildPageForIndex(int index) {
    switch (index) {
      case 0:
        return const DashboardScreen();
      case 1:
        return widget.hasOnlineAccess
            ? const OnlineChatScreen()
            : const OnlineAuthPromptScreen();
      case 2:
        return const PhoneScreen();
      case 3:
      default:
        return const SettingsScreen();
    }
  }

  void _startRealtimeServicesIfNeeded() {
    if (_realtimeServicesStarted) return;
    _realtimeServicesStarted = true;
    try {
      ChatNotificationService().start();
    } catch (error) {
      _realtimeServicesStarted = false;
      debugPrint('[HomeScreen] ChatNotificationService.start failed: $error');
      return;
    }
    try {
      FriendRequestNotificationService().start();
    } catch (error) {
      debugPrint(
        '[HomeScreen] FriendRequestNotificationService.start failed: $error',
      );
    }
  }

  Future<void> _stopRealtimeServices() async {
    _realtimeServicesStarted = false;
    try {
      await ChatNotificationService().stop();
    } catch (error) {
      debugPrint('[HomeScreen] ChatNotificationService.stop failed: $error');
    }
    try {
      await FriendRequestNotificationService().stop();
    } catch (error) {
      debugPrint(
        '[HomeScreen] FriendRequestNotificationService.stop failed: $error',
      );
    }
  }

  Future<void> _setOfflineSafely() async {
    try {
      await _chatService.setOffline();
    } catch (error) {
      debugPrint('[HomeScreen] setOffline failed: $error');
    }
  }

  Future<void> _runInitialPermissionSetup() async {
    if (_permissionsRequested) return;
    _permissionsRequested = true;

    final prefs = await SharedPreferences.getInstance();
    final alreadyCompleted = prefs.getBool(_initialPermissionsKey) ?? false;
    if (alreadyCompleted) {
      return;
    }

    if (mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Row(
            children: [
              Icon(Icons.security, color: Color(0xFF075E54)),
              SizedBox(width: 8),
              Text('App Setup'),
            ],
          ),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Smishing Shield PH now asks for permissions only when you use the matching feature, so startup stays quieter.',
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 12),
              _PermissionRow(
                icon: Icons.notifications_outlined,
                label: 'Notifications',
                description: 'Incoming calls and alerts',
              ),
              _PermissionRow(
                icon: Icons.sms_outlined,
                label: 'SMS',
                description: 'Smishing detection and SMS chat',
              ),
              _PermissionRow(
                icon: Icons.phone_outlined,
                label: 'Phone',
                description: 'Call handling and SMS support',
              ),
              _PermissionRow(
                icon: Icons.contacts_outlined,
                label: 'Contacts',
                description: 'Contact names and chat list',
              ),
              _PermissionRow(
                icon: Icons.mic_outlined,
                label: 'Microphone',
                description: 'Voice and video calls',
              ),
              _PermissionRow(
                icon: Icons.camera_alt_outlined,
                label: 'Camera',
                description: 'Video calls',
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF075E54),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Continue',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      );
    }

    await prefs.setBool(_initialPermissionsKey, true);
  }

  void _onTabTapped(int index) {
    if (index == currentIndex) return;
    setState(() {
      currentIndex = index;
      _ensurePageInitialized(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: currentIndex,
        children: List<Widget>.generate(
          _pageCache.length,
          (index) =>
              _initializedPageIndexes.contains(index) && _pageCache[index] != null
              ? _pageCache[index]!
              : const SizedBox.shrink(),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: currentIndex,
        selectedItemColor: const Color(0xFF075E54),
        unselectedItemColor: Colors.grey,
        selectedFontSize: 12.5,
        unselectedFontSize: 12,
        onTap: _onTabTapped,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            label: 'Dashboard',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'Online',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.sms_outlined),
            label: 'SMS',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _PermissionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;

  const _PermissionRow({
    required this.icon,
    required this.label,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: const Color(0xFF075E54)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
