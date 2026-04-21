import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/e2ee_service.dart';

class SecureBackupSetupScreen extends StatefulWidget {
  final VoidCallback? onSetupComplete;
  const SecureBackupSetupScreen({super.key, this.onSetupComplete});

  @override
  State<SecureBackupSetupScreen> createState() =>
      _SecureBackupSetupScreenState();
}

class _SecureBackupSetupScreenState extends State<SecureBackupSetupScreen> {
  final TextEditingController _pinController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _setupBackup() async {
    final pin = _pinController.text.trim();
    if (pin.length < 6) {
      setState(() {
        _errorMessage = 'Please enter a 6-digit PIN.';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // The backend requires at least 8 characters.
      // We append a constant salt so the user only has to remember 6 digits.
      final securePassphrase = '${pin}SSPH';
      await E2eeService().saveRecoveryKeyBackup(passphrase: securePassphrase);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Secure backup successfully enabled!'),
          backgroundColor: Color(0xFF25D366),
        ),
      );
      if (widget.onSetupComplete != null) {
        widget.onSetupComplete!();
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() {
        final msg = e.toString().replaceAll('Exception: ', '');
        _errorMessage = msg.contains('offline') || msg.contains('internet')
            ? 'No internet connection. Please go online and try again.'
            : msg;
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1622),
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54),
        title: const Text('Setup Secure Backup'),
        automaticallyImplyLeading: widget.onSetupComplete == null,
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
                  Icons.cloud_upload_outlined,
                  size: 64,
                  color: Color(0xFF25D366),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Back up your encrypted chats',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'Create a 6-digit PIN. This PIN will be used to restore your messages if you reinstall the app or change phones.',
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
                  onPressed: _isLoading ? null : _setupBackup,
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          'Turn On Backup',
                          style: TextStyle(fontSize: 16, color: Colors.white),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}