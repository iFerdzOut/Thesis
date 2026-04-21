import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/e2ee_service.dart';

class SecureBackupRestoreScreen extends StatefulWidget {
  final VoidCallback? onRestoreComplete;
  const SecureBackupRestoreScreen({super.key, this.onRestoreComplete});

  @override
  State<SecureBackupRestoreScreen> createState() =>
      _SecureBackupRestoreScreenState();
}

class _SecureBackupRestoreScreenState extends State<SecureBackupRestoreScreen> {
  final TextEditingController _pinController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _restoreBackup() async {
    final pin = _pinController.text.trim();
    if (pin.length < 6) {
      setState(() {
        _errorMessage = 'Please enter your 6-digit PIN.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // We append the same constant salt used during setup
      final securePassphrase = '${pin}SSPH';
      await E2eeService()
          .restoreIdentityFromRecoveryKey(passphrase: securePassphrase);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chats successfully restored!'),
          backgroundColor: Color(0xFF25D366),
        ),
      );
      
      // Pop with true to indicate success to the previous screen
      if (widget.onRestoreComplete != null) {
        widget.onRestoreComplete!();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Incorrect PIN or backup not found.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _confirmResetBackup() async {
    final confirm = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text('Reset Cloud Backup?'),
            content: const Text(
                'If you forgot your PIN, you cannot restore your old messages. '
                'Resetting will permanently delete your old cloud backup and let you start fresh.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete Backup',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ) ??
        false;

    if (!confirm || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await E2eeService().clearRemoteBackup();
      if (mounted) {
        if (widget.onRestoreComplete != null) {
          widget.onRestoreComplete!();
        } else {
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = 'Failed to reset backup.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                'Enter your Backup PIN',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'Enter the 6-digit PIN you created previously to restore your encrypted chat history.',
                style: TextStyle(fontSize: 14, color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 32,
                  letterSpacing: 16,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  counterText: "",
                  hintText: '••••••',
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
                      : const Text(
                          'Restore',
                          style: TextStyle(fontSize: 16, color: Colors.white),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: _isLoading ? null : _confirmResetBackup,
                child: const Text(
                  'Forgot PIN? Reset Backup',
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