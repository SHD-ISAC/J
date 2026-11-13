import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../consts/eh_consts.dart';
import '../enum/config_enum.dart';
import '../service/local_config_service.dart';
import '../utils/cookie_util.dart';
import 'eh_cache_manager.dart';

class EHCookieManager extends Interceptor {
  static const _requestSession = 'ehCookieSession';

  final LocalConfigService localConfigService;
  Future<void> _pendingWrite = Future<void>.value();
  int _session = 0;
  int _logoutRequests = 0;
  final String _cacheRunPrefix = DateTime.now().microsecondsSinceEpoch.toString();
  List<Cookie> cookies = _defaultCookies();

  int get session => _session;
  String get cacheSession => '$_cacheRunPrefix:$_session';

  EHCookieManager(this.localConfigService);

  static List<Cookie> _defaultCookies() => [Cookie('nw', '1'), Cookie('datatags', '1')];

  Future<void> initCookies() async {
    try {
      final value = await localConfigService.read(configKey: ConfigEnum.ehCookie);
      if (value != null) {
        final list = jsonDecode(value);
        if (list is List) {
          cookies.addAll(CookieUtil.parseSetCookieHeaders(list.whereType<String>()));
        }
      }
    } on FormatException {
      // An unreadable legacy cookie file must not block anonymous requests.
    }
  }

  Future<void> storeEHCookies(List<Cookie> newCookies, {bool replaceAccount = false, int? requestSession}) {
    if (_logoutRequests > 0 || (requestSession != null && requestSession != _session)) {
      return Future<void>.value();
    }
    final incoming = <String, Cookie>{
      for (final cookie in newCookies)
        if (cookie.name != '__utmp' && (cookie.name != 'igneous' || cookie.value != 'mystery')) cookie.name: cookie,
    };
    final previousMember = cookies.where((cookie) => cookie.name == 'ipb_member_id').firstOrNull?.value;
    final newMember = incoming['ipb_member_id']?.value;
    final accountChanged = replaceAccount || (newMember != null && previousMember != newMember);
    final current = accountChanged ? _defaultCookies() : cookies;
    if (accountChanged) {
      ++_session;
    }

    final updated = <String, Cookie>{for (final cookie in current) cookie.name: cookie}..addAll(incoming);
    if (!accountChanged && updated.length == cookies.length && cookies.every((cookie) => updated[cookie.name]?.value == cookie.value)) {
      return Future<void>.value();
    }
    final values = updated.values.toList();
    final generation = _session;
    final previous = cookies;
    cookies = values;
    return _persistCookies().catchError((Object error, StackTrace stack) {
      if (_session == generation && identical(cookies, values)) {
        cookies = previous;
        ++_session;
      }
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> removeCookies(List<String> cookieNames) {
    final updated = cookies.where((cookie) => !cookieNames.contains(cookie.name)).toList();
    if (updated.length == cookies.length) {
      return Future<void>.value();
    }
    cookies = updated;
    return _persistCookies();
  }

  Future<void> _persistCookies() {
    final stored = cookies.where((cookie) => cookie.name != 'nw' && cookie.name != 'datatags');
    final value = jsonEncode(stored.map((cookie) => cookie.toString()).toList());
    final isEmpty = stored.isEmpty;
    return _serializeWrite(() async {
      if (isEmpty) {
        await localConfigService.delete(configKey: ConfigEnum.ehCookie);
      } else {
        await localConfigService.write(configKey: ConfigEnum.ehCookie, value: value);
      }
    });
  }

  Future<T> _serializeWrite<T>(Future<T> Function() action) {
    final result = _pendingWrite.then((_) => action());
    _pendingWrite = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_requestSession] = _session;
    options.extra[EHCacheManager.requestCacheSessionKey] = cacheSession;
    if (_isTrustedCookieOrigin(options.uri) && _logoutRequests == 0) {
      options.headers[HttpHeaders.cookieHeader] = CookieUtil.parse2String(cookies);
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    try {
      final headers = response.headers[HttpHeaders.setCookieHeader];
      final requestSession = response.requestOptions.extra[_requestSession];
      if (headers != null && requestSession == _session && !response.extra.containsKey(CacheResponse.extraKey) && isTrustedResponse(response)) {
        final cookies = CookieUtil.parseSetCookieHeaders(headers).map((cookie) => Cookie(cookie.name, cookie.value)).toList();
        if (cookies.isNotEmpty) {
          await storeEHCookies(cookies, requestSession: requestSession as int);
        }
      }
      handler.next(response);
    } catch (error, stackTrace) {
      handler.reject(DioException(requestOptions: response.requestOptions, error: error, stackTrace: stackTrace));
    }
  }

  Future<bool> removeAllCookies() async {
    _logoutRequests++;
    ++_session;
    cookies = _defaultCookies();
    return _serializeWrite(() async {
      try {
        return await localConfigService.delete(configKey: ConfigEnum.ehCookie);
      } finally {
        ++_session;
        _logoutRequests--;
      }
    });
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
