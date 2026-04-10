import 'package:flutter/material.dart';
/// PasswordValidator
/// 
/// Enforces: min 8 chars, uppercase, lowercase, digit, special character
class PasswordValidator {
  static String? validate(String password) {
    if (password.length < 8) {
      return 'Password must be at least 8 characters';
    }
    if (!password.contains(RegExp(r'[A-Z]'))) {
      return 'Password must contain at least one uppercase letter';
    }
    if (!password.contains(RegExp(r'[a-z]'))) {
      return 'Password must contain at least one lowercase letter';
    }
    if (!password.contains(RegExp(r'[0-9]'))) {
      return 'Password must contain at least one number';
    }
    if (!password.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\;/]'))) {
      return 'Password must contain at least one special character (!@#\$%^&*...)';
    }
    return null; // valid
  }

  static double strength(String password) {
    double score = 0;
    if (password.length >= 8) score += 0.2;
    if (password.length >= 12) score += 0.1;
    if (password.contains(RegExp(r'[A-Z]'))) score += 0.2;
    if (password.contains(RegExp(r'[a-z]'))) score += 0.2;
    if (password.contains(RegExp(r'[0-9]'))) score += 0.15;
    if (password.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\;/]'))) score += 0.15;
    return score.clamp(0.0, 1.0);
  }

  static Color strengthColor(double strength) {
    if (strength < 0.4) return const Color(0xFFE53935); // red
    if (strength < 0.7) return const Color(0xFFFB8C00); // orange
    return const Color(0xFF43A047);                      // green
  }

  static String strengthLabel(double strength) {
    if (strength < 0.4) return 'Weak';
    if (strength < 0.7) return 'Fair';
    return 'Strong';
  }
}