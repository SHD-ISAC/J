import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:jhentai/src/database/dao/dio_cache_dao.dart';
import 'package:jhentai/src/setting/network_setting.dart';
import 'package:jhentai/src/service/log.dart';

import '../database/database.dart';

class EHCacheManager extends Interceptor {
  final CacheOptions _options;
  final SqliteCacheStore _store;
  final String Function() _session;
  static const requestCacheSessionKey = 'ehCacheSession';

  static const allowedStatusCodes = [
    // OK
    200,
    // Non-Authoritative Information
    203,
    // Moved Permanently
    301,
    // No-Content
    304,
    // Found
    302,
    // Temporary Redirect
    307
  ];

  static const String realUriExtraKey = 'realUri';

  EHCacheManager({required CacheOptions options, required String Function() session})
      : assert(options.store != null),
        _options = options,
        _store = options.store!,
        _session = session;

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    CacheOptions cacheOptions = _getCacheOptions(options);

    final cacheUrl = _computeCachedUrl(options, cacheOptions);
    final session = (options.extra[requestCacheSessionKey] as String?) ?? _session();
    options.extra[realUriExtraKey] = cacheUrl;
    options.extra[requestCacheSessionKey] = session;

    if (!_shouldSkipRequest(options, cacheOptions)) {
      try {
        final cached = await _getCacheStore(cacheOptions).get(CacheOptions.defaultCacheKeyBuilder(options));
        if (session == _session() && cached != null && cached.url == cacheUrl && !cached.expired()) {
          return handler.resolve(cached.toResponse(options), true);
        }
      } catch (error) {
        log.warning('Reading page cache failed', error.runtimeType);
      }
    }
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) async {
    CacheOptions cacheOptions = _getCacheOptions(response.requestOptions);

    if (_shouldSkipResponse(response, cacheOptions)) {
      return handler.next(response);
    }

    try {
      await _saveResponse(response, cacheOptions);
    } catch (error) {
      log.warning('Saving page cache failed', error.runtimeType);
    }

    handler.next(response);
  }

  Future<void> removeCacheByUrl(String url) {
    return _store.deleteWithUrl(url);
  }

  Future<void> removeCacheByUrlPrefix(String url) {
    return _store.deleteWithUrlPrefix(url);
  }

  Future<void> removeAllCache() {
    return _store.cleanAll();
  }

  CacheOptions _getCacheOptions(RequestOptions request) {
    return CacheOptions.fromExtra(request) ?? _options;
  }

  SqliteCacheStore _getCacheStore(CacheOptions options) {
    return options.store ?? _store;
  }

  String _computeCachedUrl(RequestOptions options, CacheOptions cacheOptions) {
    String cachedUrl = options.uri.toString();
    if (cacheOptions.ignoreParams) {
      Uri raw = Uri.parse(cachedUrl);
      Uri replaced = Uri(
        scheme: raw.scheme,
        userInfo: raw.userInfo,
        host: raw.host,
        port: raw.port,
        path: raw.path,
        query: null,
        fragment: raw.fragment.isEmpty ? null : raw.fragment,
      );
      cachedUrl = replaced.toString();
    }

    return cachedUrl;
  }
  
  bool _shouldSkipRequest(RequestOptions requestOptions, CacheOptions cacheOptions) {
    if (requestOptions.method.toUpperCase() == 'POST') {
      return true;
    }

    if (cacheOptions.policy != CachePolicy.cache) {
      return true;
    }

    return false;
  }

  bool _shouldSkipResponse(Response response, CacheOptions cacheOptions) {
    if (response.extra.containsKey(CacheResponse.extraKey) || response.requestOptions.extra[requestCacheSessionKey] != _session()) {
      return true;
    }

    if (response.requestOptions.method.toUpperCase() == 'POST') {
      return true;
    }

    if (cacheOptions.policy == CachePolicy.disable) {
      return true;
    }

    final cacheControl = response.headers[HttpHeaders.cacheControlHeader] ?? [];
    if (cacheControl.expand((value) => value.split(',')).any((value) => value.trim().toLowerCase() == 'no-store')) {
      return true;
    }

    if (!allowedStatusCodes.contains(response.statusCode)) {
      return true;
    }

    return false;
  }

  Future<void> _saveResponse(Response response, CacheOptions cacheOptions) async {
    CacheResponse cacheResponse = CacheResponse.fromResponse(response, cacheOptions);

    await _getCacheStore(cacheOptions).upsertCache(cacheResponse);

    response.extra[CacheResponse.extraKey] = cacheResponse.cacheKey;
  }


}

enum CachePolicy {
  /// not use and not save cache
  disable,

  /// not use but save cache
  noCache,

  /// use and save cache
  cache,
}

class CacheOptions {
  final CachePolicy policy;

  final Duration expire;

  final SqliteCacheStore? store;

  final bool ignoreParams;

  static const _extraKey = '@cache_options@';

  static get noCacheOptions => CacheOptions(policy: CachePolicy.noCache, expire: networkSetting.pageCacheMaxAge.value);

  static get noCacheOptionsIgnoreParams => CacheOptions(policy: CachePolicy.noCache, expire: networkSetting.pageCacheMaxAge.value, ignoreParams: true);

  static get cacheOptions => CacheOptions(policy: CachePolicy.cache, expire: networkSetting.pageCacheMaxAge.value);

  static get cacheOptionsIgnoreParams => CacheOptions(policy: CachePolicy.cache, expire: networkSetting.pageCacheMaxAge.value, ignoreParams: true);

  const CacheOptions({this.policy = CachePolicy.cache, required this.expire, this.store, this.ignoreParams = false});

  static CacheOptions? fromExtra(RequestOptions request) {
    return request.extra[_extraKey];
  }

  static String defaultCacheKeyBuilder(RequestOptions request) {
    final session = request.extra[EHCacheManager.requestCacheSessionKey];
    final url = request.extra[EHCacheManager.realUriExtraKey];
    return sha256.convert(utf8.encode('$session:${request.responseType}:$url')).toString();
  }

  Map<String, dynamic> toExtra() {
    return {_extraKey: this};
  }

  Options toOptions() {
    return Options(extra: toExtra());
  }

  CacheOptions copyWith({CachePolicy? policy, Duration? expire, SqliteCacheStore? store}) {
    return CacheOptions(policy: policy ?? this.policy, expire: expire ?? this.expire, store: store ?? this.store);
  }
}

class CacheResponse {
  final String url;

  final String cacheKey;

  final Uint8List content;

  final Uint8List headers;

  final DateTime expireDate;

  static const extraKey = '@cache_key@';

  CacheResponse({required this.url, required this.cacheKey, required this.content, required this.headers, required this.expireDate});

  static CacheResponse fromResponse(Response response, CacheOptions options) {
    return CacheResponse(
      content: _serializeContent(response.requestOptions.responseType, response.data),
      expireDate: DateTime.now().add(options.expire),
      headers: utf8.encode(jsonEncode(Map.of(response.headers.map)..removeWhere((key, _) => key.toLowerCase() == HttpHeaders.setCookieHeader))),
      cacheKey: CacheOptions.defaultCacheKeyBuilder(response.requestOptions),
      url: response.requestOptions.extra[EHCacheManager.realUriExtraKey] ?? response.requestOptions.uri.toString(),
    );
  }

  Response toResponse(RequestOptions options) {
    return Response(
      data: _deserializeContent(options.responseType, content),
      extra: {extraKey: cacheKey},
      headers: _getHeaders(),
      statusCode: 304,
      requestOptions: options,
    );
  }

  bool expired() {
    return DateTime.now().isAfter(expireDate);
  }

  Headers _getHeaders() {
    Headers h = Headers();
    final decoded = jsonDecode(utf8.decode(headers)) as Map<String, dynamic>;
    for (final entry in decoded.entries) {
      if (entry.key.toLowerCase() != HttpHeaders.setCookieHeader) {
        h.set(entry.key, entry.value);
      }
    }
    return h;
  }

  static Uint8List _serializeContent(ResponseType type, dynamic content) {
    if (content == null) {
      return Uint8List(0);
    }

    switch (type) {
      case ResponseType.bytes:
        return content;
      case ResponseType.plain:
        return utf8.encode(content);
      case ResponseType.json:
        return utf8.encode(jsonEncode(content));
      default:
        throw UnsupportedError('Response type not supported : $type.');
    }
  }

  static dynamic _deserializeContent(ResponseType type, List<int>? content) {
    switch (type) {
      case ResponseType.bytes:
        return content;
      case ResponseType.plain:
        return (content != null) ? utf8.decode(content) : null;
      case ResponseType.json:
        return (content != null) ? jsonDecode(utf8.decode(content)) : null;
      default:
        throw UnsupportedError('Response type not supported : $type.');
    }
  }


}

class SqliteCacheStore {
  final AppDb appDb;

  SqliteCacheStore({required this.appDb});

  Future<void> purgeLegacy() => DioCacheDao.deleteLegacyCache();

  Future<void> cleanExpired() {
    return DioCacheDao.deleteCacheByDate(DateTime.now());
  }

  Future<void> cleanAll() {
    return DioCacheDao.deleteAllCache();
  }

  Future<void> deleteWithUrl(String url) {
    return DioCacheDao.deleteCacheByUrl(url);
  }

  Future<void> deleteWithUrlPrefix(String urlPrefix) {
    return DioCacheDao.deleteCacheLikeUrl(urlPrefix + '%');
  }

  Future<CacheResponse?> get(String key) {
    Future<DioCacheData?> future = DioCacheDao.selectByCacheKey(key);

    return future.then((value) {
      if (value == null) {
        return null;
      }
      return CacheResponse(url: value.url, cacheKey: value.cacheKey, content: value.content, headers: value.headers, expireDate: value.expireDate);
    });
  }

  Future<void> upsertCache(CacheResponse response) {
    return DioCacheDao.upsertCache(
      DioCacheData(
        url: response.url,
        cacheKey: response.cacheKey,
        content: response.content,
        headers: response.headers,
        expireDate: response.expireDate,
      ),
    );
  }
}
