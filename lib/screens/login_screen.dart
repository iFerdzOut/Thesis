import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../services/auth_service.dart';
import '../services/e2ee_service.dart';
import 'register_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController emailController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  bool isLoading = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  // ── Friendly Firebase error messages ─────────────────────────────────
  String _friendlyError(dynamic e) {
    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'user-not-found':
          return 'No account found with this email address.';
        case 'wrong-password':
          return 'Incorrect password. Please try again.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'user-disabled':
          return 'This account has been disabled. Contact support.';
        case 'too-many-requests':
          return 'Too many failed attempts. Please try again later.';
        case 'network-request-failed':
          return 'No internet connection. Please check your network.';
        case 'invalid-credential':
          return 'Incorrect email or password. Please try again.';
        case 'missing-email':
          return 'Please enter your email address first.';
        default:
          return 'Login failed. Please check your credentials.';
      }
    }
    return 'Login failed. Please try again.';
  }

  Future<void> loginUser() async {
    final email = emailController.text.trim();
    final password = passwordController.text;

    // Validation
    if (email.isEmpty && password.isEmpty) {
      _showError('Please enter your email and password.');
      return;
    }
    if (email.isEmpty) {
      _showError('Please enter your email address.');
      return;
    }
    if (password.isEmpty) {
      _showError('Please enter your password.');
      return;
    }

    setState(() => isLoading = true);

    try {
      await AuthService().login(email: email, password: password);

      // FIX: await the full E2EE bootstrap so sessions and device keys are
      // restored before the user opens a chat. The old code used
      // scheduleAutomaticAccountBootstrap() which is fire-and-forget and
      // races with chat open, causing decryption failures on login.
      // bootstrapIfNeeded() is idempotent — safe to call on every login.
      try {
        await E2eeService().bootstrapIfNeeded(
          accountPassword: password,
          syncRemote: true,
        );
      } catch (e) {
        // Non-fatal: if bootstrap fails here (e.g. offline), the app will
        // retry automatically on next launch via
        // scheduleAutomaticAccountBootstrapIfPossible(). Log for diagnostics.
        debugPrint('[LoginScreen] E2EE bootstrap warning (non-fatal): $e');
      }

      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (!mounted) return;
      _showError(_friendlyError(e));
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

  void _showSuccess(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.check_circle_outline,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: const Color(0xFF0E8F63),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _forgotPassword() async {
    final email = emailController.text.trim();
    if (email.isEmpty) {
      _showError('Enter your email address first, then tap Forgot password.');
      return;
    }

    setState(() => isLoading = true);
    try {
      await AuthService().sendPasswordResetEmail(email: email);
      if (!mounted) return;
      _showSuccess('Password reset email sent to $email');
    } catch (e) {
      if (!mounted) return;
      _showError(_friendlyError(e));
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 40),

              // ── Logo ──────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: const Color(0xFF075E54).withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.shield,
                  size: 64,
                  color: Color(0xFF075E54),
                ),
              ),
              const SizedBox(height: 20),

              const Text(
                'Smishing Shield PH',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF075E54),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Secure messaging for Filipino users',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 40),

              // ── Email ─────────────────────────────────────────────
              TextField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email',
                  hintText: 'Enter your email',
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: Color(0xFF075E54), width: 2),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Password ──────────────────────────────────────────
              TextField(
                controller: passwordController,
                obscureText: _obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: 'Enter your password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      color: Colors.grey,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide:
                        const BorderSide(color: Color(0xFF075E54), width: 2),
                  ),
                ),
                onSubmitted: (_) => loginUser(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: isLoading ? null : _forgotPassword,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF075E54),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 8,
                    ),
                  ),
                  child: const Text(
                    'Forgot password?',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // ── Login Button ──────────────────────────────────────
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
                  onPressed: isLoading ? null : loginUser,
                  child: isLoading
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5),
                        )
                      : const Text(
                          'Login',
                          style: TextStyle(
                              fontSize: 16,
                              color: Colors.white,
                              fontWeight: FontWeight.w600),
                        ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Register Link ─────────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text("Don't have an account? ",
                      style: TextStyle(color: Colors.grey)),
                  GestureDetector(
                    onTap: () => Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => const RegisterScreen()),
                    ),
                    child: const Text(
                      'Register',
                      style: TextStyle(
                        color: Color(0xFF075E54),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}