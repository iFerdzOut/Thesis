// ignore_for_file: avoid_print

/// OtpWhitelistService
///
/// Detects OTP/verification messages and whitelists them
/// so they are never flagged as smishing — false positives
/// on OTP messages are extremely annoying for users.
///
/// Logic: if message matches OTP pattern AND sender is in
/// trusted sender list, skip AI detection entirely.
class OtpWhitelistService {

  // ── Trusted OTP senders (Philippine telcos, banks, gov) ──────────────
  static const List<String> _trustedSenders = [
    // Philippine telcos
    'GLOBE', 'SMART', 'TNT', 'SUN', 'DITO',
    // Banks
    'BDO', 'BPI', 'METROBANK', 'LANDBANK', 'DBP',
    'UNIONBANK', 'RCBC', 'SECURITY BANK', 'CHINABANK',
    'EASTWEST', 'PSBANK', 'MAYBANK',
    // E-wallets
    'GCASH', 'MAYA', 'PAYMAYA', 'COINS', 'GRABPAY',
    // Government
    'SSS', 'GSIS', 'PHILHEALTH', 'PAGIBIG', 'PSA',
    'COMELEC', 'BIR', 'LTO', 'NBI',
    // Delivery
    'LAZADA', 'SHOPEE', 'JNTEXPRESS', 'NINJAVAN',
  ];

  // ── OTP message patterns ──────────────────────────────────────────────
  static final List<RegExp> _otpPatterns = [
    // "Your OTP is 123456"
    RegExp(r'\bOTP\b.{0,30}\d{4,8}', caseSensitive: false),
    // "Verification code: 123456"
    RegExp(r'verif\w*\s*code[:\s]+\d{4,8}', caseSensitive: false),
    // "Your code is 123456"
    RegExp(r'\bcode\b.{0,20}\d{4,8}', caseSensitive: false),
    // "PIN: 123456"
    RegExp(r'\bPIN[:\s]+\d{4,8}', caseSensitive: false),
    // "TAC: 123456"
    RegExp(r'\bTAC[:\s]+\d{4,8}', caseSensitive: false),
    // "One-time password"
    RegExp(r'one.time\s*password', caseSensitive: false),
    // "Do not share this code"
    RegExp(r'do not share.{0,20}code', caseSensitive: false),
    // Just a 6-digit number alone (common OTP format)
    RegExp(r'^\s*\d{6}\s*$'),
  ];

  /// Returns true if the message is likely an OTP and should be whitelisted.
  /// [sender] — the phone number or sender ID
  /// [message] — the message body
  static bool isOtp(String sender, String message) {
    final senderUpper = sender.toUpperCase().trim();
    final isTrustedSender = _trustedSenders.any(
      (s) => senderUpper.contains(s),
    );

    final hasOtpPattern = _otpPatterns.any(
      (pattern) => pattern.hasMatch(message),
    );

    if (hasOtpPattern) {
      print('[OtpWhitelist] OTP pattern detected from $sender — whitelisted');
      return true;
    }

    // If from a trusted sender AND message is short (< 160 chars)
    // and contains a number, likely an OTP
    if (isTrustedSender && message.length < 160) {
      final hasNumber = RegExp(r'\d{4,8}').hasMatch(message);
      if (hasNumber) {
        print('[OtpWhitelist] Trusted sender OTP from $sender — whitelisted');
        return true;
      }
    }

    return false;
  }
}