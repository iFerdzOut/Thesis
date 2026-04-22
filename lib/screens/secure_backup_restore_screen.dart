import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/e2ee_service.dart';
import 'secure_backup_setup_screen.dart';

enum _RestoreMode {
  pin,
  recoveryCode,
}

class SecureBackupRestoreScreen extends StatefulWidget {
  final VoidCallback? onRestoreComplete;
  final VoidCallback? onEmailResetComplete;
  const SecureBackupRestoreScreen({
    super.key,
    this.onRestoreComplete,
    this.onEmailResetComplete,
  });

  @override
  State<SecureBackupRestoreScreen> createState() =>
      _SecureBackupRestoreScreenState();
}

class _SecureBackupRestoreScreenState extends State<SecureBackupRestoreScreen> {
  final TextEditingController _secretController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  _RestoreMode _mode = _RestoreMode.pin;

  @override
  void dispose() {
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _restoreBackup() async {
    final String secret = _secretController.text.trim();
    if (_mode == _RestoreMode.pin && !RegExp(r'^\d{6}$').hasMatch(secret)) {
      setState(() => _errorMessage = 'Please enter your 6-digit PIN.');
      return;
    }
    if (_mode == _RestoreMode.recoveryCode && secret.isEmpty) {
      setState(() => _errorMessage = 'Please enter your recovery code.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_mode == _RestoreMode.pin) {
        await E2eeService().restoreFromPin(pin: secret);
      } else {
        await E2eeService().restoreFromRecoveryCode(recoveryCode: secret);
      }

      if (!mounted) return;
      if (_mode == _RestoreMode.recoveryCode) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SecureBackupSetupScreen(
              onSetupComplete: () => Navigator.of(context).pop(),
            ),
          ),
        );
        if (!mounted) return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chats successfully restored!'),
          backgroundColor: Color(0xFF25D366),
        ),
      );
      if (widget.onRestoreComplete != null) {
        widget.onRestoreComplete!();
      } else {
        if (!mounted) return;
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _confirmEmailReset() async {
    final bool confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Reset via Email?'),
            content: const Text(
              'Resetting via email erases encrypted history for security. Proceed?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text(
                  'Proceed',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirm) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final String? email = AuthService().currentUser?.email;
      if (email == null || email.trim().isEmpty) {
        throw Exception('Your account has no email address to reset.');
      }
      await AuthService().sendPasswordResetEmail(email: email.trim());
      await E2eeService().resetEncryptedHistoryForEmailRecovery();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Password reset email sent to $email. Your encrypted backup was cleared.',
          ),
        ),
      );
      widget.onEmailResetComplete?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString().replaceAll('Exception: ', '');
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool pinMode = _mode == _RestoreMode.pin;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1622),
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54),
        title: const Text('Restore Chats'),
        automaticallyImplyLeading: widget.onRestoreComplete == null,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF25D366).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.lock_reset,
                  size: 64,
                  color: Color(0xFF25D366),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Restore encrypted history',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                pinMode
                    ? 'Enter your 6-digit PIN to derive the local restore key.'
                    : 'Enter your 16-character recovery code, then create a new PIN.',
                style: const TextStyle(fontSize: 14, color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              SegmentedButton<_RestoreMode>(
                segments: const [
                  ButtonSegment<_RestoreMode>(
                    value: _RestoreMode.pin,
                    label: Text('PIN'),
                  ),
                  ButtonSegment<_RestoreMode>(
                    value: _RestoreMode.recoveryCode,
                    label: Text('Recovery Code'),
                  ),
                ],
                selected: <_RestoreMode>{_mode},
                onSelectionChanged: (selection) {
                  setState(() {
                    _mode = selection.first;
                    _secretController.clear();
                    _errorMessage = null;
                  });
                },
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _secretController,
                keyboardType:
                    pinMode ? TextInputType.number : TextInputType.text,
                obscureText: pinMode,
                maxLength: pinMode ? 6 : null,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: pinMode ? 32 : 22,
                  letterSpacing: pinMode ? 16 : 2,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                inputFormatters: pinMode
                    ? [FilteringTextInputFormatter.digitsOnly]
                    : const <TextInputFormatter>[],
                decoration: InputDecoration(
                  counterText: '',
                  hintText: pinMode ? '• • • • • •' : 'ABCD-EFGH-IJKL-MNOP',
                  hintStyle: const TextStyle(color: Colors.white24),
                  filled: true,
                  fillColor: const Color(0xFF101C2B),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                  errorText: _errorMessage,
                ),
                onChanged: (_) => setState(() => _errorMessage = null),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  onPressed: _isLoading ? null : _restoreBackup,
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(
                          pinMode
                              ? 'Restore with PIN'
                              : 'Restore with Recovery Code',
                          style: const TextStyle(
                              fontSize: 16, color: Colors.white),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _isLoading ? null : _confirmEmailReset,
                child: const Text(
                  'Reset via Email',
                  style: TextStyle(color: Colors.white54, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
