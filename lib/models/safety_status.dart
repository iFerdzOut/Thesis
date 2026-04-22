enum SafetyStatus {
  safe,
  scanning,
  malicious;

  String get value => name;

  static SafetyStatus fromValue(String? value) {
    switch (value?.trim()) {
      case 'scanning':
        return SafetyStatus.scanning;
      case 'malicious':
        return SafetyStatus.malicious;
      case 'safe':
      default:
        return SafetyStatus.safe;
    }
  }
}
