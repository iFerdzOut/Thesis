import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';

import 'firebase_options.dart';
import 'screens/call_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/contacts_screen.dart';
import 'screens/home_screen.dart';
import 'services/auth_service.dart';
import 'services/call_notification_service.dart';
import 'services/chat_notification_service.dart';
import 'services/e2ee_service.dart';
import 'services/fcm_call_service.dart';
import 'services/fcm_chat_service.dart';
import 'services/friend_request_notification_service.dart';
import 'services/session_identity_service.dart';
import 'services/sms_service.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  debugPrint(
    '[FCM Background] Received message: type=${message.data['type']} '
    'callId=${message.data['callId']}',
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final imageCache = PaintingBinding.instance.imageCache;
  imageCache.maximumSize = 60;
  imageCache.maximumSizeBytes = 48 << 20;

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const SmishingShieldApp());
}

class _SplashGate extends StatefulWidget {
  const _SplashGate();

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _showSplash = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return const _SplashScreen();
    }
    return const AuthGate();
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF075E54),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0B6D60),
              Color(0xFF075E54),
              Color(0xFF041B17),
            ],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white12,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Icon(
                    Icons.shield_rounded,
                    size: 72,
                    color: Colors.white,
                  ),
                ),
              ),
              SizedBox(height: 22),
              Text(
                'Smishing Shield PH',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              SizedBox(height: 8),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  'Secure SMS and encrypted messaging with anti-smishing protection.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    height: 1.4,
                  ),
                ),
              ),
              SizedBox(height: 26),
              SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SmishingShieldApp extends StatelessWidget {
  const SmishingShieldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Smishing Shield PH',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _AppScrollBehavior(),
      themeAnimationDuration: const Duration(milliseconds: 180),
      theme: ThemeData(
        primaryColor: const Color(0xFF075E54),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF075E54),
          primary: const Color(0xFF075E54),
          secondary: const Color(0xFF25D366),
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F7F7),
        splashFactory: InkRipple.splashFactory,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          },
        ),
        useMaterial3: true,
        appBarTheme: const AppBarTheme(
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
      ),
      home: const _SplashGate(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(
      parent: AlwaysScrollableScrollPhysics(),
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  static const Duration _authRestoreGracePeriod = Duration(seconds: 8);

  bool _callServicesStarted = false;
  final Set<String> _activeIncomingRouteKeys = <String>{};
  final Set<String> _activeChatRouteKeys = <String>{};
  bool _deferredBootstrapStarted = false;
  StreamSubscription<User?>? _authSubscription;
  User? _currentAuthUser;
  bool _authStreamReady = false;
  bool _authMarkerLoaded = false;
  bool _expectsAuthenticatedRestore = false;
  bool _authRestoreGraceElapsed = false;
  Timer? _authRestoreTimer;
  String? _lastPersistedAuthUid;
  bool _staleSessionMarkerCleared = false;

  @override
  void initState() {
    super.initState();
    SmsService.onSmsNotificationTap = ({
      required String sender,
      required String body,
      required int timestampMs,
    }) {
      _openSmsScreenFromNotification(sender: sender);
    };
    SmsService.onSmsComposeIntentTap = ({
      required String phone,
      String? body,
    }) {
      _openSmsComposeIntent(phone: phone, body: body);
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_ensureDeferredBootstrapStarted());
    });
    unawaited(_initializeAuthSessionState());
  }

  @override
  void dispose() {
    SmsService.onSmsNotificationTap = null;
    SmsService.onSmsComposeIntentTap = null;
    _authRestoreTimer?.cancel();
    _authSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeAuthSessionState() async {
    final expectedRestore = await AuthService.hasPersistedSessionMarker();
    final currentUser = FirebaseAuth.instance.currentUser;
    if (!mounted) return;

    setState(() {
      _authMarkerLoaded = true;
      _currentAuthUser = currentUser;
      _authStreamReady = currentUser != null || !expectedRestore;
      _expectsAuthenticatedRestore = expectedRestore;
      _authRestoreGraceElapsed = !expectedRestore || currentUser != null;
      _lastPersistedAuthUid = (currentUser != null && !currentUser.isAnonymous)
          ? currentUser.uid
          : null;
      _staleSessionMarkerCleared = false;
    });

    if (expectedRestore && currentUser == null) {
      _startAuthRestoreTimer();
    }

    _authSubscription ??= FirebaseAuth.instance.idTokenChanges().listen(
      _handleAuthStateChanged,
      onError: (Object error) {
        debugPrint('[AuthGate] auth stream error: $error');
        if (!mounted) return;
        setState(() {
          _authStreamReady = true;
        });
      },
    );
  }

  void _startAuthRestoreTimer() {
    _authRestoreTimer?.cancel();
    _authRestoreTimer = Timer(_authRestoreGracePeriod, () {
      if (!mounted) return;
      setState(() {
        _authRestoreGraceElapsed = true;
        _authStreamReady = true;
      });
      // Do NOT clear the marker here — Firebase may still be finishing its
      // token refresh on a slow network. _clearStalePersistedSessionMarker()
      // is only called by _handleAuthStateChanged when Firebase explicitly
      // confirms user == null (genuine session expiry / revocation).
    });
  }

  void _handleAuthStateChanged(User? user) {
    if (!mounted) return;

    _currentAuthUser = user;
    _authStreamReady = true;

    if (user != null && !user.isAnonymous) {
      // Auth restored successfully — cancel the timer and mark ready.
      _authRestoreTimer?.cancel();
      _staleSessionMarkerCleared = false;
      setState(() {
        _expectsAuthenticatedRestore = true;
        _authRestoreGraceElapsed = true;
      });
      if (_lastPersistedAuthUid != user.uid) {
        _lastPersistedAuthUid = user.uid;
        unawaited(AuthService.persistSessionMarker(user));
      }
      _startCallServicesOnce();
      return;
    }

    _stopCallServices();
    setState(() {});

    // FIX: Firebase sometimes emits user=null briefly on cold start before
    // resolving the persisted token. We must NOT clear the session marker
    // just because we got a null emission — that would log the user out
    // every time the app is killed and reopened.
    //
    // Safe rule: only clear the marker if we were NOT expecting a restore
    // (i.e. the user genuinely has no session), OR if we are inside the
    // grace window and waiting (let the timer handle the timeout).
    // Never clear proactively from a null emission while a restore is expected.
    if (_expectsAuthenticatedRestore) {
      if (!_authRestoreGraceElapsed) {
        // Still inside the grace window — keep waiting.
        _startAuthRestoreTimer();
      }
      // Grace elapsed but restore was expected: hold state, do not clear.
      // The user may have lost internet briefly. They remain "logged in"
      // in the UI. If they explicitly log out, AuthService.logout() clears
      // the marker directly.
      return;
    }

    // No restore was expected — this is a genuine signed-out state.
    _clearStalePersistedSessionMarker();
  }

  void _clearStalePersistedSessionMarker() {
    if (_staleSessionMarkerCleared || !_expectsAuthenticatedRestore) {
      return;
    }
    _staleSessionMarkerCleared = true;
    _lastPersistedAuthUid = null;
    unawaited(AuthService.clearPersistedSessionMarker());
    if (!mounted) return;
    setState(() {
      _expectsAuthenticatedRestore = false;
      _authRestoreGraceElapsed = true;
    });
  }

  Future<String> _resolveCallerDisplayName({
    required Map<String, dynamic> callData,
    required String fallbackCallerName,
  }) async {
    final primaryName = (callData['callerName'] as String?)?.trim();
    if (primaryName != null &&
        primaryName.isNotEmpty &&
        primaryName.toLowerCase() != 'unknown caller') {
      return primaryName;
    }

    if (fallbackCallerName.trim().isNotEmpty &&
        fallbackCallerName.trim().toLowerCase() != 'unknown caller') {
      return fallbackCallerName.trim();
    }

    final callerId = (callData['callerId'] as String?)?.trim();
    if (callerId == null || callerId.isEmpty) {
      return fallbackCallerName;
    }

    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(callerId)
          .get();
      final userData = userDoc.data();
      final resolvedName =
          (userData?['name'] as String?)?.trim().isNotEmpty == true
              ? (userData!['name'] as String).trim()
              : (userData?['displayName'] as String?)?.trim().isNotEmpty == true
                  ? (userData!['displayName'] as String).trim()
                  : (userData?['email'] as String?)?.trim().isNotEmpty == true
                      ? (userData!['email'] as String).trim()
                      : null;

      return resolvedName ?? fallbackCallerName;
    } catch (_) {
      return fallbackCallerName;
    }
  }

  Future<void> _openIncomingCallScreen({
    required String action,
    required String callId,
    required String callerName,
    required bool isVideo,
  }) async {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    final routeKey = '$callId|$action';
    if (_activeIncomingRouteKeys.contains(routeKey)) {
      debugPrint('[AuthGate] Duplicate incoming route ignored: $routeKey');
      return;
    }

    _activeIncomingRouteKeys.add(routeKey);

    try {
      final doc = await FirebaseFirestore.instance
          .collection('calls')
          .doc(callId)
          .get();

      if (!doc.exists) {
        debugPrint('[AuthGate] Incoming call doc missing: $callId');
        _activeIncomingRouteKeys.remove(routeKey);
        return;
      }

      final data = doc.data()!;
      final status = data['status'] as String? ?? '';
      if (status == 'ended' ||
          status == 'declined' ||
          status == 'missed' ||
          status == 'cancelled') {
        debugPrint(
          '[AuthGate] Ignoring incoming route for terminal status: $callId status=$status',
        );
        _activeIncomingRouteKeys.remove(routeKey);
        return;
      }

      final resolvedCallerId = data['callerId'] as String? ?? '';
      final resolvedCallerName = await _resolveCallerDisplayName(
        callData: data,
        fallbackCallerName: callerName,
      );
      final resolvedIsVideo = data['isVideo'] as bool? ?? isVideo;
      final autoAnswer =
          action == 'com.example.flutter_application_1.ACTION_ACCEPT_CALL';

      navigator
          .push(
            MaterialPageRoute(
              builder: (_) => CallScreen(
                contactName: resolvedCallerName,
                receiverId: resolvedCallerId,
                isVideo: resolvedIsVideo,
                isCaller: false,
                incomingCallId: callId,
                autoAnswer: autoAnswer,
              ),
            ),
          )
          .whenComplete(() => _activeIncomingRouteKeys.remove(routeKey));
    } catch (e) {
      _activeIncomingRouteKeys.remove(routeKey);
      debugPrint('[AuthGate] Failed to open incoming call screen: $e');
    }
  }

  void _openChatScreenFromNotification({
    required String chatId,
    required String senderId,
    required String senderName,
  }) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    if (_activeChatRouteKeys.contains(chatId)) {
      debugPrint('[AuthGate] Duplicate chat route ignored: $chatId');
      return;
    }

    _activeChatRouteKeys.add(chatId);
    navigator
        .push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              contactName: senderName,
              phone: '',
              chatType: 'online',
              receiverId: senderId,
            ),
          ),
        )
        .whenComplete(() => _activeChatRouteKeys.remove(chatId));
  }

  void _openContactsScreenFromFriendRequest() {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null) return;

    navigator.push(
      MaterialPageRoute(
        builder: (_) => const ContactsScreen(initialTabIndex: 1),
      ),
    );
  }

  void _openSmsScreenFromNotification({
    required String sender,
  }) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || sender.trim().isEmpty) return;

    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactName: sender,
          phone: sender,
          chatType: 'sms',
        ),
      ),
    );
  }

  void _openSmsComposeIntent({
    required String phone,
    String? body,
  }) {
    final navigator = appNavigatorKey.currentState;
    if (navigator == null || phone.trim().isEmpty) return;

    navigator.push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          contactName: phone,
          phone: phone,
          chatType: 'sms',
          initialDraftText: body,
        ),
      ),
    );
  }

  void _startCallServicesOnce() {
    if (_callServicesStarted) return;
    _callServicesStarted = true;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_callServicesStarted) return;
      debugPrint('[AuthGate] Starting Call Services...');
      final callService = CallNotificationService();

      callService.onIncomingCallFromBackground = ({
        required String action,
        required String callId,
        required String callerName,
        required bool isVideo,
      }) {
        _openIncomingCallScreen(
          action: action,
          callId: callId,
          callerName: callerName,
          isVideo: isVideo,
        );
      };

      try {
        callService.setupNativeCallHandler();
        callService.startListening();
      } catch (error, stackTrace) {
        debugPrint('[AuthGate] Call service startup failed: $error');
        debugPrint('$stackTrace');
      }

      final chatNotificationService = ChatNotificationService();
      chatNotificationService.onChatNotificationTap = ({
        required String chatId,
        required String senderId,
        required String senderName,
      }) {
        _openChatScreenFromNotification(
          chatId: chatId,
          senderId: senderId,
          senderName: senderName,
        );
      };
      try {
        chatNotificationService.setupNativeChatHandler();
      } catch (error, stackTrace) {
        debugPrint('[AuthGate] Chat handler startup failed: $error');
        debugPrint('$stackTrace');
      }

      // FIX: This is a background safety-net for app resume (e.g. killed and
      // reopened without going through login). It intentionally stays
      // fire-and-forget here because login_screen.dart and
      // register_screen.dart now both await bootstrapIfNeeded() before
      // navigating, so by the time the user opens a chat the bootstrap is
      // already complete. This call only catches edge cases (token refresh,
      // cold resume) and bootstrapIfNeeded() is idempotent — it will skip
      // silently if bootstrap already ran this session.
      E2eeService().scheduleAutomaticAccountBootstrapIfPossible();

      final friendRequestService = FriendRequestNotificationService();
      friendRequestService.onFriendRequestNotificationTap = ({
        required String senderId,
        required String senderName,
      }) {
        _openContactsScreenFromFriendRequest();
      };
      try {
        friendRequestService.setupNativeFriendRequestHandler();
      } catch (error, stackTrace) {
        debugPrint('[AuthGate] Friend request handler startup failed: $error');
        debugPrint('$stackTrace');
      }

      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted || !_callServicesStarted) return;
      try {
        await FcmCallService().init();
      } catch (error, stackTrace) {
        debugPrint('[AuthGate] FcmCallService.init failed: $error');
        debugPrint('$stackTrace');
      }

      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!mounted || !_callServicesStarted) return;
      try {
        FcmChatService().initForegroundNotifications();
      } catch (error, stackTrace) {
        debugPrint(
          '[AuthGate] FcmChatService.initForegroundNotifications failed: $error',
        );
        debugPrint('$stackTrace');
      }
    });
  }

  Future<void> _ensureDeferredBootstrapStarted() async {
    if (_deferredBootstrapStarted) return;
    _deferredBootstrapStarted = true;
    await SessionIdentityService.instance.initialize();
    SmsService.init();
    try {
      await CallNotificationService.configure();
    } catch (error, stackTrace) {
      debugPrint('[AuthGate] Call notification configure failed: $error');
      debugPrint('$stackTrace');
    }
  }

  void _stopCallServices() {
    if (!_callServicesStarted) return;
    _callServicesStarted = false;
    debugPrint('[AuthGate] Stopping Call Services...');
    CallNotificationService().stopListening();
  }

  @override
  Widget build(BuildContext context) {
    final shouldWaitForRestore = !_authMarkerLoaded ||
        !_authStreamReady ||
        (_expectsAuthenticatedRestore &&
            !_authRestoreGraceElapsed &&
            (_currentAuthUser == null || _currentAuthUser!.isAnonymous));

    if (shouldWaitForRestore) {
      return const Scaffold(
        backgroundColor: Color(0xFF075E54),
        body: Center(
          child: CircularProgressIndicator(color: Colors.white),
        ),
      );
    }

    final user = _currentAuthUser ?? FirebaseAuth.instance.currentUser;
    final hasOnlineAccess = user != null && !user.isAnonymous;
    final hasSession = user != null;

    if (hasOnlineAccess) {
      _startCallServicesOnce();
    } else {
      _stopCallServices();
    }

    return HomeScreen(
      hasSession: hasSession,
      hasOnlineAccess: hasOnlineAccess,
    );
  }
}