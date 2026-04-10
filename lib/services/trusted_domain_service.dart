import '../models/trusted_domain_model.dart';
import 'local_detection_repository.dart';
import 'trusted_domains_service.dart';
import 'url_extraction_service.dart';

class TrustedDomainService {
  TrustedDomainService._internal();

  static final TrustedDomainService instance = TrustedDomainService._internal();
  factory TrustedDomainService() => instance;

  final LocalDetectionRepository _repository = LocalDetectionRepository();
  final UrlExtractionService _urlExtractionService = UrlExtractionService();
  final Set<String> _runtimeTrustedDomains = <String>{};
  bool _primed = false;

  Future<void> initialize() async {
    if (_primed) {
      return;
    }
    await _repository.initialize();
    final domains = await _repository.listTrustedDomains();
    _runtimeTrustedDomains
      ..clear()
      ..addAll(domains.map((TrustedDomainModel item) => item.domain));
    _primed = true;
  }

  String normalizeDomain(String raw) {
    return _urlExtractionService.extractDomain(raw).toLowerCase().trim();
  }

  bool isUrlTrustedCached(String url) {
    final domain = normalizeDomain(url);
    return _isRuntimeTrusted(domain) || TrustedDomainsService.isUrlTrusted(url);
  }

  Future<bool> isUrlTrusted(String url) async {
    await initialize();
    final domain = normalizeDomain(url);
    if (_isRuntimeTrusted(domain)) {
      return true;
    }
    if (TrustedDomainsService.isUrlTrusted(url)) {
      return true;
    }
    final stored = await _repository.isTrustedDomain(domain);
    if (stored) {
      _runtimeTrustedDomains.add(domain);
    }
    return stored;
  }

  Future<bool?> areAllUrlsTrusted(List<String> urls) async {
    if (urls.isEmpty) {
      return null;
    }
    for (final String url in urls) {
      if (!await isUrlTrusted(url)) {
        return false;
      }
    }
    return true;
  }

  Future<List<Map<String, dynamic>>> analyzeUrls(List<String> urls) async {
    await initialize();
    final results = <Map<String, dynamic>>[];
    for (final String url in urls) {
      final domain = normalizeDomain(url);
      results.add(<String, dynamic>{
        'url': url,
        'domain': domain,
        'trusted': _isRuntimeTrusted(domain) || TrustedDomainsService.isUrlTrusted(url),
      });
    }
    return results;
  }

  Future<void> addTrustedDomain({
    required String rawDomainOrUrl,
    required String source,
    String? note,
  }) async {
    await initialize();
    final domain = normalizeDomain(rawDomainOrUrl);
    if (domain.isEmpty) {
      return;
    }
    _runtimeTrustedDomains.add(domain);
    await _repository.upsertTrustedDomain(
      domain: domain,
      source: source,
      note: note,
    );
  }

  bool _isRuntimeTrusted(String domain) {
    if (_runtimeTrustedDomains.contains(domain)) {
      return true;
    }
    return _runtimeTrustedDomains.any(
      (String trusted) => domain == trusted || domain.endsWith('.$trusted'),
    );
  }
}
