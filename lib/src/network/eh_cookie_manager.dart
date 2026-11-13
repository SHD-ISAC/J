import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../consts/eh_consts.dart';
import '../enum/config_enum.dart';
import '../service/local_config_service.dart';
import '../utils/cookie_util.dart';

class EHCookieManager extends Interceptor {
  final LocalConfigService localConfigService;

  List<Cookie> cookies = [Cookie('nw', '1'), Cookie('datatags', '1')];

  EHCookieManager(this.localConfigService);

  Future<void> initCookies() async {
    String? string = await localConfigService.read(configKey: ConfigEnum.ehCookie);
    if (string != null) {
      List list = jsonDecode(string);
      cookies.addAll(list.cast<String>().map(Cookie.fromSetCookieValue).toList());
    }
  }

  Future<void> replaceCookies(List<Cookie> cookies) async {
    this.cookies.removeWhere((cookie) => cookies.any((c) => c.name == cookie.name));
    this.cookies.addAll(cookies);

    List<Cookie> storeCookies = List.from(this.cookies)..removeWhere((cookie) => cookie.name == 'nw' || cookie.name == 'datatags');
    await localConfigService.write(configKey: ConfigEnum.ehCookie, value: jsonEncode(storeCookies.map((cookie) => cookie.toString()).toList()));
  }

  Future<void> removeCookies(List<String> cookieNames) async {
    cookies.removeWhere((cookie) => cookieNames.any((name) => cookie.name == name));

    List<Cookie> storeCookies = List.from(cookies)..removeWhere((cookie) => cookie.name == 'nw' || cookie.name == 'datatags');
    await localConfigService.write(configKey: ConfigEnum.ehCookie, value: jsonEncode(storeCookies.map((cookie) => cookie.toString()).toList()));
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    try {
      if (_isTrustedCookieOrigin(options.uri)) {
        options.headers[HttpHeaders.cookieHeader] = CookieUtil.parse2String(cookies);
      }
      handler.next(options);
    } on Exception catch (e, stackTrace) {
      var err = DioException(requestOptions: options, error: e, stackTrace: stackTrace);
      handler.reject(err, true);
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    try {
      await _saveEHCookies(response);
      handler.next(response);
    } on Exception catch (e, s) {
      final err = DioException(requestOptions: response.requestOptions, error: e, stackTrace: s);
      return handler.reject(err, true);
    }
  }

  Future<void> storeEHCookies(List<Cookie> cookies) async {
    /// https://github.com/Ehviewer-Overhauled/Ehviewer/issues/873
    cookies.removeWhere((cookie) => cookie.name == '__utmp');
    cookies.removeWhere((cookie) => cookie.name == 'igneous' && cookie.value == 'mystery');
    await replaceCookies(cookies);
  }

  Future<bool> removeAllCookies() async {
    bool success = await localConfigService.delete(configKey: ConfigEnum.ehCookie);
    cookies = [Cookie('nw', '1'), Cookie('datatags', '1')];
    return success;
  }

  Future<void> _saveEHCookies(Response response) async {
    final headers = response.headers[HttpHeaders.setCookieHeader];
    if (headers == null || !isTrustedResponse(response)) {
      return;
    }

    final cookies = CookieUtil.parseSetCookieHeaders(headers).map((cookie) => Cookie(cookie.name, cookie.value)).toList();
    if (cookies.isNotEmpty) {
      await storeEHCookies(cookies);
    }
  }

  static bool isTrustedResponse(Response response) {
    var uri = response.requestOptions.uri;
    if (!_isTrustedCookieOrigin(uri)) {
      return false;
    }
    for (final redirect in response.redirects) {
      uri = uri.resolveUri(redirect.location);
      if (!_isTrustedCookieOrigin(uri)) {
        return false;
      }
    }
    return true;
  }

  static bool _isTrustedCookieOrigin(Uri uri) {
    return uri.isScheme('https') && uri.port == 443 && EHConsts.requestHosts.contains(uri.host);
  }
}
