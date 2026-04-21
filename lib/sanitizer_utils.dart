class SanitizerUtils {
  /// Sanitizes PII before passing data to ML feedback loops or SQLite logging.
  /// Replaces phone numbers with [PHONE] and 4-12 digit strings with [NUMBER].
  static String sanitizePii(String input) {
    String sanitized = input;
    
    // Basic Phone Number Regex (Matches PH format +639... or 09...)
    final phoneRegex = RegExp(r'(\+63|0)[0-9]{10}');
    sanitized = sanitized.replaceAll(phoneRegex, '[PHONE]');
    
    // Any continuous string of 4 to 12 digits (OTP codes, IDs, etc.)
    final numberRegex = RegExp(r'\b\d{4,12}\b');
    sanitized = sanitized.replaceAll(numberRegex, '[NUMBER]');
    
    return sanitized;
  }
}