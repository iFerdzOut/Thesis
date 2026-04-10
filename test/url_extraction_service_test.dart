import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_application_1/services/url_extraction_service.dart';

void main() {
  final service = UrlExtractionService();

  group('UrlExtractionService', () {
    test('extracts bare help domains', () {
      final urls = service.extractUrls(
        'Claim now at w1plsMega.help before the promo ends.',
      );

      expect(urls, contains('w1plsMega.help'));
    });

    test('extracts wrapped help domains', () {
      final urls = service.extractUrls(
        '<;w1plsMega.help;> Celebrate family time this Sunday!',
      );

      expect(urls, contains('w1plsMega.help'));
    });

    test('normalizes defanged hxxps help links', () {
      final normalized =
          service.normalizeUrl('hxxps[:]//mega[.]help/redeem-now');

      expect(normalized, 'https://mega.help/redeem-now');
    });

    test('extracts www help links', () {
      final urls = service.extractUrls(
        'Visit www.example.help to read the advisory.',
      );

      expect(urls, contains('www.example.help'));
    });

    test('does not extract email addresses as urls', () {
      final urls = service.extractUrls(
        'Email support at user@example.com for assistance.',
      );

      expect(urls, isEmpty);
    });
  });
}
