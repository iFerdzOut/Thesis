import 'package:flutter/material.dart';

import 'login_screen.dart';
import 'register_screen.dart';

class OnlineAuthPromptScreen extends StatelessWidget {
  const OnlineAuthPromptScreen({super.key});

  static const Color _bgColor = Color(0xFF07131D);
  static const Color _surfaceColor = Color(0xFF10212E);
  static const Color _accentColor = Color(0xFF25D366);
  static const Color _headerColor = Color(0xFF075E54);
  static const Color _textPrimary = Color(0xFFF5FAFF);
  static const Color _textMuted = Color(0xFF93A4B5);

  void _openLogin(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  void _openRegister(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RegisterScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        backgroundColor: _headerColor,
        toolbarHeight: 0,
        elevation: 0,
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _headerColor,
                  Color(0xFF0B6D60),
                ],
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Online Chat',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 29,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Sign in to unlock online encrypted messaging and friend requests.',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: _surfaceColor,
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white10),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 20,
                          offset: Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 78,
                          height: 78,
                          decoration: BoxDecoration(
                            color: _accentColor.withValues(alpha: 0.14),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _accentColor.withValues(alpha: 0.30),
                            ),
                          ),
                          child: const Icon(
                            Icons.lock_person_outlined,
                            color: _accentColor,
                            size: 38,
                          ),
                        ),
                        const SizedBox(height: 18),
                        const Text(
                          'Use SMS without an account',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _textPrimary,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Your Phone and SMS tabs stay available in guest mode. Sign in only when you want online chat, encrypted messaging, and contact requests.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _textMuted,
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: const Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _PromptBullet(
                                icon: Icons.sms_outlined,
                                text: 'SMS inbox, send, receive, quarantine, and smishing alerts still work.',
                              ),
                              SizedBox(height: 10),
                              _PromptBullet(
                                icon: Icons.chat_bubble_outline,
                                text: 'Online chat, E2EE, calls, and friend requests need an account.',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _accentColor,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: () => _openLogin(context),
                            child: const Text(
                              'Login to Online Chat',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.14),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
                            onPressed: () => _openRegister(context),
                            child: const Text(
                              'Create an Account',
                              style: TextStyle(
                                color: _textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PromptBullet extends StatelessWidget {
  final IconData icon;
  final String text;

  const _PromptBullet({
    required this.icon,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: OnlineAuthPromptScreen._accentColor),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: OnlineAuthPromptScreen._textMuted,
              fontSize: 13.2,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
