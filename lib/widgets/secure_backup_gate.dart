import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../services/e2ee_service.dart';
import '../screens/secure_backup_setup_screen.dart';
import '../screens/secure_backup_restore_screen.dart';

class SecureBackupGate extends StatefulWidget {
  final Widget child;

  /// Wraps a screen (like the Home Screen) to ensure the user has either
  /// restored their cloud backup or set up a new 6-digit PIN.
  const SecureBackupGate({super.key, required this.child});

  @override
  State<SecureBackupGate> createState() => _SecureBackupGateState();
}

class _SecureBackupGateState extends State<SecureBackupGate> {
  static final Set<String> _sessionUnlockedUsers = <String>{};

  bool _isChecking = true;
  bool _needsSetup = false;
  bool _needsRestore = false;
  bool _isOffline = false;
  bool _unlockedThisSession = false;

  // ── Local-cache key ────────────────────────────────────────────────────────
  // Written after the user successfully completes setup/restore (or when we
  // confirm both local identity AND remote backup exist).  On the next launch
  // we fast-path past the Firestore round-trip unless the local identity is
  // gone (indicating a reinstall that needs restore).
  @override
  void initState() {
    super.initState();
    _checkState();
  }

  void _syncSessionStateForUser(String? uid) {
    final normalizedUid = uid?.trim();
    if (normalizedUid == null || normalizedUid.isEmpty) {
      _sessionUnlockedUsers.clear();
      _unlockedThisSession = false;
      return;
    }
    _unlockedThisSession = _sessionUnlockedUsers.contains(normalizedUid);
  }

  void _markUnlockedForCurrentSession(String uid) {
    final normalizedUid = uid.trim();
    if (normalizedUid.isEmpty) {
      return;
    }
    _sessionUnlockedUsers.add(normalizedUid);
    _unlockedThisSession = true;
  }

  Future<void> _checkState() async {
    if (!mounted) return;
    setState(() {
      _isChecking = true;
      _needsSetup = false;
      _needsRestore = false;
      _isOffline = false;
    });

    final uid = FirebaseAuth.instance.currentUser?.uid;
    _syncSessionStateForUser(uid);
    if (uid == null) {
      if (mounted) setState(() => _isChecking = false);
      return;
    }

    final e2ee = E2eeService();

    // ── Fast-path: already confirmed this session ──────────────────────────
    // If we have previously confirmed that BOTH local identity and remote
    // backup are healthy, skip the Firestore round-trip on every subsequent
    // launch — only re-verify when local identity is no longer present
    // (which is the only case that requires a restore or fresh setup).
    try {
      const confirmed = null;
      if (confirmed == 'true') {
        final hasLocal = await e2ee.hasLocalIdentity();
        if (hasLocal) {
          // Identity intact — proceed directly, re-publish in background.
          unawaited(e2ee.ensureReady());
          if (mounted) setState(() => _isChecking = false);
          return;
        }
        // Local identity is gone (reinstall) — fall through to full check.
        // No-op: confirmation marker disabled (we require PIN unlock per login).
      }
    } catch (_) {
      // Secure-storage read errors are non-fatal; fall through to full check.
    }

    // ── Full check (first launch or identity gone) ─────────────────────────
    bool hasLocal = false;
    try {
      hasLocal = await e2ee.hasLocalIdentity();
    } catch (error) {
      debugPrint('[SecureBackupGate] hasLocalIdentity error: $error');
    }

    late final RemoteBackupStatus remoteStatus;
    try {
      remoteStatus = await e2ee.getRemoteBackupStatus();
    } catch (error) {
      debugPrint(
          '[SecureBackupGate] getRemoteBackupStatus error (offline?): $error');
      // Server unreachable — if the user has no local identity (reinstall),
      // show an offline/retry UI instead of silently failing open.
      if (!hasLocal && mounted) {
        setState(() {
          _isOffline = true;
          _isChecking = false;
        });
      } else if (mounted) {
        // Has local identity — safe to proceed; will re-check on next launch.
        setState(() => _isChecking = false);
      }
      return;
    }

    if (!mounted) return;

    if (remoteStatus.requiresPinRestore) {
      if (!_unlockedThisSession) {
        // User has a remote backup but hasn't entered PIN this session
        // Show restore screen to decrypt messages
        if (!mounted) return;
        setState(() {
          _needsRestore = true;
          _isChecking = false;
        });
        return;
      }
      // Already unlocked this session, proceed with app
      debugPrint(
          '[SecureBackupGate] Already unlocked this session, proceeding');
      unawaited(e2ee.ensureReady());
      if (mounted) setState(() => _isChecking = false);
      return;
    }

    // No remote backup configured: ensure we have a local identity (so the setup
    // screen can immediately back up the generated keys), then require setup.
    if (!hasLocal) {
      try {
        await e2ee.ensureReady();
      } catch (_) {}
    } else {
      unawaited(e2ee.ensureReady());
    }

    setState(() {
      _needsSetup = true;
      _isChecking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1622),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF25D366)),
        ),
      );
    }

    if (_isOffline) {
      return Scaffold(
        backgroundColor: const Color(0xFF0B1622),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.wifi_off, size: 64, color: Colors.white54),
                const SizedBox(height: 24),
                const Text(
                  'No internet connection',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'A connection is needed to check your cloud backup. '
                  'Please connect to the internet and tap Retry.',
                  style: TextStyle(fontSize: 14, color: Colors.white70),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                    minimumSize: const Size(160, 48),
                  ),
                  onPressed: () {
                    setState(() {
                      _isOffline = false;
                      _isChecking = true;
                    });
                    _checkState();
                  },
                  child: const Text(
                    'Retry',
                    style: TextStyle(fontSize: 16, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_needsRestore) {
      return PopScope(
        canPop: false,
        child: SecureBackupRestoreScreen(
          onRestoreComplete: () async {
            final uid = FirebaseAuth.instance.currentUser?.uid;
            // User successfully entered PIN and restored backup
            // Mark as unlocked for this session
            if (uid != null) {
              _markUnlockedForCurrentSession(uid);
            }
            debugPrint(
                '[SecureBackupGate] Backup restore complete, unlocking session');
            if (mounted) {
              setState(() {
                _needsRestore = false;
                _isChecking = true;
              });
              // Wait a moment for UI to update, then check state again
              await Future.delayed(const Duration(milliseconds: 100));
              _checkState();
            }
          },
          onEmailResetComplete: () {
            final uid = FirebaseAuth.instance.currentUser?.uid;
            if (!mounted) return;
            // Email reset clears backup, so user needs new setup
            if (uid != null) {
              _markUnlockedForCurrentSession(uid);
            }
            debugPrint(
                '[SecureBackupGate] Email reset complete, clearing backup');
            setState(() {
              _needsRestore = false;
              _isChecking = true;
            });
            _checkState();
          },
        ),
      );
    }

    if (_needsSetup) {
      return PopScope(
        canPop: false,
        child: SecureBackupSetupScreen(
          onSetupComplete: () async {
            final uid = FirebaseAuth.instance.currentUser?.uid;
            // User successfully set up PIN and backup
            // Mark as unlocked for this session
            if (uid != null) {
              _markUnlockedForCurrentSession(uid);
            }
            debugPrint(
                '[SecureBackupGate] Backup setup complete, unlocking session');
            if (mounted) {
              setState(() {
                _needsSetup = false;
                _isChecking = true;
              });
              // Wait a moment for UI to update, then check state again
              await Future.delayed(const Duration(milliseconds: 100));
              _checkState();
            }
          },
        ),
      );
    }

    return widget.child;
  }
}
