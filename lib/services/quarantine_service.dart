import 'url_extraction_service.dart';

class QuarantineService {
  QuarantineService._internal();

  static final QuarantineService instance = QuarantineService._internal();
  factory QuarantineService() => instance;

  final UrlExtractionService _urlExtractionService = UrlExtractionService();

  String defangText(String rawText) {
    String output = rawText;
    final List<String> urls = _urlExtractionService.extractUrls(rawText);
    for (final String url in urls.toSet()) {
      output = output.replaceAll(url, _urlExtractionService.defangUrl(url));
    }
    return output;
  }
}
