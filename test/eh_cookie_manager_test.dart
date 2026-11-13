import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/network/eh_cookie_manager.dart';

void main() {
  test('trusts HTTPS on a configured cookie host through relative redirects', () {
    final response = Response<void>(
      requestOptions: RequestOptions(path: 'https://exhentai.org/'),
      redirects: [RedirectRecord(302, 'GET', Uri.parse('/login'))],
    );

    expect(EHCookieManager.isTrustedResponse(response), isTrue);
  });

  test('rejects cookie responses from other origins', () {
    for (final url in ['http://exhentai.org', 'https://exhentai.org:8443', 'https://example.test']) {
      final response = Response<void>(requestOptions: RequestOptions(path: url));

      expect(EHCookieManager.isTrustedResponse(response), isFalse);
    }
  });

  test('rejects cookie responses after redirects through another origin', () {
    final response = Response<void>(
      requestOptions: RequestOptions(path: 'https://exhentai.org/'),
      redirects: [RedirectRecord(302, 'GET', Uri.parse('https://example.test/')), RedirectRecord(302, 'GET', Uri.parse('https://exhentai.org/'))],
    );

    expect(EHCookieManager.isTrustedResponse(response), isFalse);
  });
}
