import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();

  bool _isChecking = true;
  bool _needsSetup = false;
  bool _needsRestore = false;
  bool _isOffline = false;

  // ── Local-cache key ────────────────────────────────────────────────────────
  // Written after the user successfully completes setup/restore (or when we
  // confirm both local identity AND remote backup exist).  On the next launch
  // we fast-path past the Firestore round-trip unless the local identity is
  // gone (indicating a reinstall that needs restore).
  static String _confirmedKey(String uid) => 'backup_gate_confirmed_$uid';

  @override
  void initState() {
    super.initState();
    _checkState();
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
      final confirmed =
          await _secureStorage.read(key: _confirmedKey(uid));
      if (confirmed == 'true') {
        final hasLocal = await e2ee.hasLocalIdentity();
        if (hasLocal) {
          // Identity intact — proceed directly, re-publish in background.
          unawaited(e2ee.ensureReady());
          if (mounted) setState(() => _isChecking = false);
          return;
        }
        // Local identity is gone (reinstall) — fall through to full check.
        await _secureStorage.delete(key: _confirmedKey(uid));
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

    bool? hasRemote;
    try {
      hasRemote = await e2ee.hasRemoteBackup();
    } catch (error) {
      debugPrint('[SecureBackupGate] hasRemoteBackup error (offline?): $error');
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

    if (!hasLocal && hasRemote) {
      // Fresh install, backup exists → MUST RESTORE
      setState(() {
        _needsRestore = true;
        _isChecking = false;
      });
    } else if (hasLocal && !hasRemote) {
      // Local identity exists, no backup → MUST SETUP PIN
      setState(() {
        _needsSetup = true;
        _isChecking = false;
      });
    } else if (!hasLocal && !hasRemote) {
      // Completely fresh → bootstrap identity, then MUST SETUP PIN
      try {
        await e2ee.ensureReady();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _needsSetup = true;
          _isChecking = false;
        });
      }
    } else {
      // Local identity AND remote backup both present → all good
      try {
        await e2ee.ensureReady();
        await _markConfirmed(uid);
      } catch (_) {}
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  Future<void> _markConfirmed(String uid) async {
    try {
      await _secureStorage.write(key: _confirmedKey(uid), value: 'true');
    } catch (_) {}
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
            if (uid != null) await _markConfirmed(uid);
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
            if (uid != null) await _markConfirmed(uid);
            setState(() {
              _needsSetup = false;
              _isChecking = true;
            });
            _checkState();
          },
        ),
      );
    }

    return widget.child;
  }
}
