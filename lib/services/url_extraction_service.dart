class UrlExtractionService {
  UrlExtractionService._internal();

  static final UrlExtractionService instance = UrlExtractionService._internal();
  factory UrlExtractionService() => instance;

  static final RegExp _schemedUrlPattern = RegExp(
    r'(?:(?:https?|hxxps?|hxxp)://|(?:https?|hxxps?|hxxp)\[:\]//|hxxps?\[\://\]|https?\[\://\]|www\.)[^\s<>()]+',
    caseSensitive: false,
  );
  static final RegExp _bareDomainPattern = RegExp(
    r'(?<![@\w])(?:[a-z0-9](?:[a-z0-9\-]{0,61}[a-z0-9])?\.)+(?:[a-z]{2,24})(?:/[^\s<>()]*)?',
    caseSensitive: false,
  );

  List<String> extractUrls(String text) {
    final matches = <String>[];
    final seen = <String>{};

    void collect(RegExp pattern) {
      for (final Match match in pattern.allMatches(text)) {
        final raw = _sanitizeExtractedUrl(match.group(0) ?? '');
        if (raw.isEmpty) {
          continue;
        }
        final normalizedKey = raw.toLowerCase();
        if (seen.add(normalizedKey)) {
          matches.add(raw);
        }
      }
    }

    collect(_schemedUrlPattern);
    collect(_bareDomainPattern);
    return matches;
  }

  String normalizeUrl(String rawUrl) {
    var cleaned = _sanitizeExtractedUrl(rawUrl);
    cleaned = cleaned
        .replaceAll(RegExp(r'^hxxps\[:\]//', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^hxxp\[:\]//', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^https\[:\]//', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^http\[:\]//', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^hxxps\[://\]', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^hxxp\[://\]', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^https\[://\]', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^http\[://\]', caseSensitive: false), 'http://')
        .replaceAll(RegExp(r'^hxxps://', caseSensitive: false), 'https://')
        .replaceAll(RegExp(r'^hxxp://', caseSensitive: false), 'http://')
        .replaceAll('[.]', '.');
    cleaned = _sanitizeExtractedUrl(cleaned);
    if (cleaned.startsWith('www.')) {
      cleaned = 'https://$cleaned';
    }
    if (!cleaned.contains('://')) {
      cleaned = 'https://$cleaned';
    }
    return cleaned;
  }

  String extractDomain(String rawUrl) {
    try {
      final uri = Uri.parse(normalizeUrl(rawUrl));
      final host = uri.host.toLowerCase();
      return host.startsWith('www.') ? host.substring(4) : host;
    } catch (_) {
      final fallback = rawUrl
          .trim()
          .toLowerCase()
          .replaceAll('[.]', '.')
          .replaceAll(RegExp(r'^https?://'), '');
      return fallback.split('/').first.replaceFirst('www.', '');
    }
  }

  String defangUrl(String rawUrl) {
    final normalized = normalizeUrl(rawUrl);
    final defanged = normalized
        .replaceAll('https://', 'hxxps[:]//')
        .replaceAll('http://', 'hxxp[:]//');
    final separator = defanged.indexOf('://');
    if (separator < 0) {
      return defanged.replaceAll('.', '[.]');
    }
    final prefix = defanged.substring(0, separator + 3);
    final suffix = defanged.substring(separator + 3).replaceAll('.', '[.]');
    return '$prefix$suffix';
  }

  String _sanitizeExtractedUrl(String input) {
    var value = input.trim();
    while (value.isNotEmpty) {
      final trimmed = value
          .replaceFirst(RegExp("^[<\\(\\[\\{'\"`;,+]+"), '')
          .replaceFirst(RegExp("[>\\)\\]\\}'\"`;,+]+\$"), '')
          .replaceFirst(RegExp(r'[\.,!?;:]+$'), '');
      if (trimmed == value) {
        break;
      }
      value = trimmed.trim();
    }
    return value;
  }
}
