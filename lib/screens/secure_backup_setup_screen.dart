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
  String? _recoveryCode;
  bool _recoveryCodeCopied = false;

  @override
  void dispose() {
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _setupBackup() async {
    final String pin = _pinController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
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
      final String recoveryCode =
          await E2eeService().setupZeroKnowledgePin(pin: pin);
      if (!mounted) return;
      setState(() {
        _recoveryCode = recoveryCode;
        _recoveryCodeCopied = false;
      });
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

  Future<void> _copyRecoveryCode() async {
    final String code = _recoveryCode?.trim() ?? '';
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    setState(() => _recoveryCodeCopied = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Recovery code copied. Save it somewhere secure.'),
      ),
    );
  }

  void _finishSetup() {
    if (widget.onSetupComplete != null) {
      widget.onSetupComplete!();
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool showingRecoveryCode = _recoveryCode != null;

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
              Text(
                showingRecoveryCode
                    ? 'Save your recovery code'
                    : 'Back up your encrypted chats',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                showingRecoveryCode
                    ? 'This code is your fallback if you forget your PIN. The server never sees your PIN, so you must save this code before you continue.'
                    : 'Create a 6-digit PIN. It is used locally to derive the key that restores your encrypted history on a new device.',
                style: const TextStyle(fontSize: 14, color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              if (!showingRecoveryCode)
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
                    counterText: '',
                    hintText: '• • • • • •',
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
                )
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: const Color(0xFF101C2B),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: const Color(0xFF25D366)),
                  ),
                  child: SelectableText(
                    _recoveryCode!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
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
                  onPressed: _isLoading
                      ? null
                      : showingRecoveryCode
                          ? (_recoveryCodeCopied
                              ? _finishSetup
                              : _copyRecoveryCode)
                          : _setupBackup,
                  child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : Text(
                          showingRecoveryCode
                              ? (_recoveryCodeCopied
                                  ? 'I Saved My Recovery Code'
                                  : 'Copy Recovery Code')
                              : 'Turn On Backup',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                          ),
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
