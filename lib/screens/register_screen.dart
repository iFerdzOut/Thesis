import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/auth_service.dart';
import '../services/device_contact_sync_service.dart';
import '../services/e2ee_service.dart';
import '../utils/password_validator.dart';
import 'login_screen.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController emailController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  final TextEditingController confirmPasswordController =
      TextEditingController();

  bool isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  double _passwordStrength = 0;

  String? _nameError;
  String? _emailError;
  String? _phoneError;
  String? _passwordError;
  String? _confirmError;

  @override
  void dispose() {
    nameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  void _onPasswordChanged(String value) {
    setState(() {
      _passwordStrength = PasswordValidator.strength(value);
      _passwordError = null;
    });
  }

  String _friendlyError(dynamic e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'email-already-in-use':
          return 'email-already-in-use';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'weak-password':
          return 'Password is too weak. Please follow the requirements.';
        case 'network-request-failed':
          return 'No internet connection. Please check your network.';
        default:
          return 'Registration failed. Please try again.';
      }
    }
    return 'Registration failed. Please try again.';
  }

  Future<void> registerUser() async {
    setState(() {
      _nameError = null;
      _emailError = null;
      _phoneError = null;
      _passwordError = null;
      _confirmError = null;
    });

    final name = nameController.text.trim();
    final email = emailController.text.trim();
    final phone = phoneController.text.trim();
    final password = passwordController.text;
    final confirmPassword = confirmPasswordController.text;

    var hasError = false;

    if (name.isEmpty) {
      _nameError = 'Please enter your display name.';
      hasError = true;
    }

    if (email.isEmpty) {
      _emailError = 'Please enter your email address.';
      hasError = true;
    } else if (!RegExp(r'^[\w\.\+\-]+@[\w\-]+\.\w+$').hasMatch(email)) {
      _emailError = 'Please enter a valid email address.';
      hasError = true;
    }

    final phoneMatchKey = DeviceContactSyncService.normalizePhone(phone);
    if (phone.isEmpty) {
      _phoneError = 'Please enter your phone number.';
      hasError = true;
    } else if (phoneMatchKey.length < 10) {
      _phoneError = 'Please enter a valid mobile number.';
      hasError = true;
    }

    final passwordError = PasswordValidator.validate(password);
    if (passwordError != null) {
      _passwordError = passwordError;
      hasError = true;
    }

    if (confirmPassword.isEmpty) {
      _confirmError = 'Please confirm your password.';
      hasError = true;
    } else if (password != confirmPassword) {
      _confirmError = 'Passwords do not match.';
      hasError = true;
    }

    if (hasError) {
      setState(() {});
      return;
    }

    setState(() => isLoading = true);

    try {
      final credential = await AuthService().register(
        email: email,
        password: password,
      );

      final uid = credential.user!.uid;
      await Future.wait([
        credential.user!.updateDisplayName(name),
        FirebaseFirestore.instance.collection('users').doc(uid).set({
          'uid': uid,
          'email': email,
          'name': name,
          'displayName': name,
          'phone': phone,
          'phoneMatchKey': phoneMatchKey,
          'isOnline': false,
          'presenceMode': 'online',
          'createdAt': FieldValue.serverTimestamp(),
        }),
      ]);

      // Navigate home immediately — E2EE bootstrap is expensive (PBKDF2 ×3 +
      // RSA key generation + backup) and must NOT block the registration UI.
      // scheduleAutomaticAccountBootstrap runs it in the background; the first
      // chat open triggers ensureDeviceIdentity which waits for it to finish.
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      E2eeService().scheduleAutomaticAccountBootstrap(accountPassword: password);
    } catch (e) {
      if (!mounted) return;
      final msg = _friendlyError(e);

      if (msg == 'email-already-in-use') {
        setState(() {
          _emailError =
              'This email is already registered. Try logging in instead.';
        });
      } else {
        _showError(msg);
      }
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    String? errorText,
    bool obscure = false,
    bool? showToggle,
    VoidCallback? onToggle,
    TextInputType? keyboardType,
    void Function(String)? onChanged,
    void Function(String)? onSubmitted,
    TextCapitalization capitalization = TextCapitalization.none,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType: keyboardType,
          textCapitalization: capitalization,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            errorText: errorText,
            prefixIcon: Icon(icon),
            suffixIcon: showToggle == true
                ? IconButton(
                    icon: Icon(
                      obscure
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: Colors.grey,
                    ),
                    onPressed: onToggle,
                  )
                : null,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: errorText != null ? Colors.red : Colors.grey.shade300,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: errorText != null ? Colors.red : const Color(0xFF075E54),
                width: 2,
              ),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: Colors.red, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }

  Widget _reqRow(String text, bool met) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 14,
            color: met ? Colors.green : Colors.grey.shade400,
          ),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              fontSize: 11,
              color: met ? Colors.green : Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strengthColor = PasswordValidator.strengthColor(_passwordStrength);
    final strengthLabel = PasswordValidator.strengthLabel(_passwordStrength);

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 32),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF075E54).withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.security,
                  size: 64,
                  color: Color(0xFF075E54),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Create Account',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF075E54),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Register for Smishing Shield PH',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 32),
              _buildField(
                controller: nameController,
                label: 'Display Name',
                hint: 'e.g. Juan dela Cruz',
                icon: Icons.person_outline,
                errorText: _nameError,
                capitalization: TextCapitalization.words,
                onChanged: (_) => setState(() => _nameError = null),
              ),
              const SizedBox(height: 16),
              _buildField(
                controller: emailController,
                label: 'Email',
                hint: 'Enter your email',
                icon: Icons.email_outlined,
                errorText: _emailError,
                keyboardType: TextInputType.emailAddress,
                onChanged: (_) => setState(() => _emailError = null),
              ),
              const SizedBox(height: 16),
              _buildField(
                controller: phoneController,
                label: 'Phone Number',
                hint: 'e.g. 09171234567',
                icon: Icons.phone_outlined,
                errorText: _phoneError,
                keyboardType: TextInputType.phone,
                onChanged: (_) => setState(() => _phoneError = null),
              ),
              const SizedBox(height: 16),
              _buildField(
                controller: passwordController,
                label: 'Password',
                hint: 'e.g. Matcha123!',
                icon: Icons.lock_outline,
                errorText: _passwordError,
                obscure: _obscurePassword,
                showToggle: true,
                onToggle: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                onChanged: _onPasswordChanged,
              ),
              if (passwordController.text.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _passwordStrength,
                          backgroundColor: Colors.grey.shade200,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(strengthColor),
                          minHeight: 5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      strengthLabel,
                      style: TextStyle(
                        color: strengthColor,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Password requirements:',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _reqRow(
                        'At least 8 characters',
                        passwordController.text.length >= 8,
                      ),
                      _reqRow(
                        'One uppercase letter (A-Z)',
                        passwordController.text.contains(RegExp(r'[A-Z]')),
                      ),
                      _reqRow(
                        'One lowercase letter (a-z)',
                        passwordController.text.contains(RegExp(r'[a-z]')),
                      ),
                      _reqRow(
                        'One number (0-9)',
                        passwordController.text.contains(RegExp(r'[0-9]')),
                      ),
                      _reqRow(
                        'One special character (!@#\$%...)',
                        passwordController.text.contains(
                          RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\;/]'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              _buildField(
                controller: confirmPasswordController,
                label: 'Confirm Password',
                hint: 'Re-enter your password',
                icon: Icons.lock_outline,
                errorText: _confirmError,
                obscure: _obscureConfirm,
                showToggle: true,
                onToggle: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
                onChanged: (_) => setState(() => _confirmError = null),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF075E54),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 2,
                  ),
                  onPressed: isLoading ? null : registerUser,
                  child: isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : const Text(
                          'Register',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    'Already have an account? ',
                    style: TextStyle(color: Colors.grey),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const LoginScreen(),
                      ),
                    ),
                    child: const Text(
                      'Login',
                      style: TextStyle(
                        color: Color(0xFF075E54),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}
