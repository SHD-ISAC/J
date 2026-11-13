import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as path;

import '../setting/network_setting.dart';
import '../service/local_config_service.dart';
import '../enum/config_enum.dart';

enum ExEchStatus { unused, accepted, failed }

final exEchStatus = ExEchStatus.unused.obs;

bool isEchFailure(DioException error) => error.error is _EchException;

/// Uses the packaged TLS client for EX when ECH is explicitly enabled.
/// Dio keeps ownership of cookies, response decoding and download streams.
class ExEchAdapter implements HttpClientAdapter {
  static const _host = 'exhentai.org';
  static const _resolver = 'https://dns.google/resolve?name=$_host&type=65';
  static const _redirectCodes = {301, 302, 303, 307, 308};

  final _defaultAdapter = HttpClientAdapter();
  final _resolverClient = Dio(BaseOptions(connectTimeout: const Duration(seconds: 6), receiveTimeout: const Duration(seconds: 6)));
  final _connections = _ConcurrentRequests(8);
  final _processes = <Process>{};
  ({String encoded, DateTime expires})? _echConfig;
  Future<String>? _lookup;

  static bool get isAvailable => (Platform.isMacOS || Platform.isLinux) && File(_helperPath).existsSync();
  static String get _helperPath => path.join(path.dirname(Platform.resolvedExecutable), 'jhentai-ech');

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (!networkSetting.enableExEch.value || options.uri.host != _host) {
      return _defaultAdapter.fetch(options, requestStream, cancelFuture);
    }

    try {
      if (options.uri.scheme != 'https' || options.uri.port != 443 || options.uri.userInfo.isNotEmpty) {
        throw const _EchException('echInvalidRequest');
      }
      if (!isAvailable) {
        throw const _EchException('echClientMissing');
      }
      final redirects = <RedirectRecord>[];
      var uri = options.uri;
      var method = options.method.toUpperCase();
      var body = requestStream;
      final config = await (cancelFuture == null
          ? _currentConfig()
          : Future.any([_currentConfig(), cancelFuture.then<String>((_) => throw DioException.requestCancelled(requestOptions: options, reason: null))]));
      final proxy = _proxyUri();
      while (true) {
        final (result, close) = await _send(options, uri, method, config, proxy, body, cancelFuture);
        final locations = result.headers['location'];
        if (!options.followRedirects ||
            !_redirectCodes.contains(result.statusCode) ||
            locations == null ||
            locations.length != 1 ||
            (method != 'GET' && method != 'HEAD' && !(method == 'POST' && result.statusCode == 303))) {
          if (redirects.isNotEmpty) {
            return ResponseBody(
              result.stream,
              result.statusCode,
              headers: result.headers,
              statusMessage: result.statusMessage,
              redirects: redirects,
              isRedirect: result.isRedirect,
              onClose: close,
            );
          }
          return result;
        }

        close();
        final destination = uri.resolve(locations.single);
        if (redirects.length >= options.maxRedirects ||
            destination.scheme != 'https' ||
            destination.host != _host ||
            destination.port != 443 ||
            destination.userInfo.isNotEmpty) {
          throw const _EchException('echRedirectBlocked');
        }
        method = method == 'POST' ? 'GET' : method;
        redirects.add(RedirectRecord(result.statusCode, method, destination));
        uri = destination;
        body = null;
      }
    } on DioException catch (error) {
      if (error.type == DioExceptionType.cancel) {
        rethrow;
      }
      exEchStatus.value = ExEchStatus.failed;
      throw _failure(options, 'echConfigUnavailable');
    } on _EchException catch (error) {
      exEchStatus.value = ExEchStatus.failed;
      throw _failure(options, error.code);
    } on ProcessException {
      exEchStatus.value = ExEchStatus.failed;
      throw _failure(options, 'echClientMissing');
    } on TimeoutException {
      exEchStatus.value = ExEchStatus.failed;
      throw _failure(options, 'echTimedOut');
    } catch (_) {
      exEchStatus.value = ExEchStatus.failed;
      throw _failure(options, 'echFailed');
    }
  }

  DioException _failure(RequestOptions options, String key) => DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: key.tr,
        error: _EchException(key),
      );

  Future<String> _currentConfig() async {
    final config = _echConfig;
    if (config != null && DateTime.now().isBefore(config.expires)) {
      return config.encoded;
    }
    final pending = _lookup ??= _loadConfig();
    try {
      return await pending;
    } finally {
      if (identical(_lookup, pending)) {
        _lookup = null;
      }
    }
  }

  Future<String> _loadConfig() async {
    final response = await _resolverClient.get<dynamic>(
      _resolver,
      options: Options(headers: {'accept': 'application/dns-json'}, followRedirects: false),
    );
    final data = response.data;
    if (data is Map && data['Status'] == 0 && data['Answer'] is List) {
      for (final answer in (data['Answer'] as List).whereType<Map>()) {
        if (answer['type'] != 65 || answer['name'].toString().toLowerCase().replaceFirst(RegExp(r'\.$'), '') != _host) {
          continue;
        }
        final record = answer['data'];
        if (record is! String || !RegExp(r'^[1-9][0-9]* \. ').hasMatch(record)) {
          continue;
        }
        final encoded = RegExp(r'(?:^|\s)ech="?([A-Za-z0-9+/=]+)"?(?:\s|$)').firstMatch(record)?.group(1);
        if (encoded != null && encoded.length <= 8192) {
          final seconds = answer['TTL'] is int ? (answer['TTL'] as int).clamp(0, 3600) : 0;
          _echConfig = (encoded: encoded, expires: DateTime.now().add(Duration(seconds: seconds)));
          return encoded;
        }
      }
    }
    throw const _EchException('echConfigUnavailable');
  }

  String _proxyUri() {
    final type = networkSetting.proxyType.value;
    if (type == JProxyType.direct) {
      return '';
    }
    if (type == JProxyType.system) {
      final address = networkSetting.systemProxyAddress;
      if (address.isEmpty) {
        return '';
      }
      return 'http://$address';
    }
    if (type == JProxyType.socks4) {
      throw const _EchException('echProxyUnsupported');
    }
    if (localConfigService.credentialsAreLocked(ConfigEnum.networkSetting)) {
      throw const _EchException('secureStorageUnavailable');
    }
    final address = networkSetting.proxyAddress.value;
    final user = networkSetting.proxyUsername.value;
    final password = networkSetting.proxyPassword.value;
    final scheme = type == JProxyType.http ? 'http' : 'socks5';
    final auth = user != null || password != null ? '${Uri.encodeComponent(user ?? '')}:${Uri.encodeComponent(password ?? '')}@' : '';
    return '$scheme://$auth$address';
  }

  Future<(ResponseBody, void Function())> _send(
    RequestOptions options,
    Uri uri,
    String method,
    String echConfig,
    String proxy,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final releaseSlot = await _connections.acquire(cancelFuture);
    if (releaseSlot == null) {
      throw DioException.requestCancelled(requestOptions: options, reason: null);
    }
    final Process process;
    try {
      process = await Process.start(_helperPath, [], includeParentEnvironment: false);
    } catch (_) {
      releaseSlot();
      rethrow;
    }
    _processes.add(process);
    unawaited(process.stderr.drain<void>());
    unawaited(process.exitCode.then((_) {
      _processes.remove(process);
      releaseSlot();
    }));
    unawaited(cancelFuture?.then<void>((_) {
      if (_processes.contains(process)) {
        process.kill();
      }
    }));
    final headers = <String, List<String>>{
      for (final entry in options.headers.entries)
        if (entry.value != null && (requestStream != null || entry.key.toLowerCase() != 'content-length'))
          entry.key: entry.value is Iterable ? (entry.value as Iterable).map((value) => value.toString()).toList() : [entry.value.toString()],
    };
    final input = jsonEncode({
      'URL': uri.toString(),
      'Method': method,
      'Headers': headers,
      'HasBody': requestStream != null,
      'ECHConfig': echConfig,
      'ProxyURL': proxy,
      'ConnectMillis': _positiveTimeout(options.connectTimeout).inMilliseconds,
      'ReceiveMillis': _positiveTimeout(options.receiveTimeout).inMilliseconds,
    });
    process.stdin.writeln(input);
    unawaited(_writeBody(process, requestStream, options.sendTimeout));

    final cursor = StreamIterator(process.stdout);
    void close() {
      process.kill();
      unawaited(cursor.cancel());
    }

    try {
      final prefix = BytesBuilder();
      final timeout = _positiveTimeout(options.connectTimeout) + _positiveTimeout(options.receiveTimeout);
      return await (() async {
        while (await cursor.moveNext()) {
          final chunk = cursor.current;
          final end = chunk.indexOf(10);
          if (end < 0) {
            prefix.add(chunk);
            if (prefix.length > 64 * 1024) {
              throw const _EchException('echInvalidResponse');
            }
            continue;
          }
          prefix.add(chunk.sublist(0, end));
          final output = jsonDecode(utf8.decode(prefix.takeBytes())) as Map<String, dynamic>;
          final error = output['error'];
          if (error is String) {
            if (error == 'echRejected') {
              _echConfig = null;
            }
            throw _EchException(error);
          }
          if (output['echAccepted'] != true || output['status'] is! int) {
            throw const _EchException('echInvalidResponse');
          }
          final rawHeaders = output['headers'] as Map<String, dynamic>? ?? {};
          final headers = rawHeaders.map((key, value) => MapEntry(key.toLowerCase(), List<String>.from(value as List)));
          final status = output['status'] as int;
          exEchStatus.value = ExEchStatus.accepted;
          final result = ResponseBody(
            _readBody(process, cursor, chunk.sublist(end + 1), options),
            status,
            headers: headers,
            isRedirect: _redirectCodes.contains(status) && headers.containsKey('location'),
            onClose: close,
          );
          return (result, close);
        }
        throw const _EchException('echFailed');
      })()
          .timeout(timeout);
    } on FormatException {
      process.kill();
      await cursor.cancel();
      throw const _EchException('echInvalidResponse');
    } catch (_) {
      process.kill();
      await cursor.cancel();
      rethrow;
    }
  }

  Future<void> _writeBody(Process process, Stream<Uint8List>? stream, Duration? timeout) async {
    try {
      if (stream != null) {
        await process.stdin.addStream(stream).timeout(_positiveTimeout(timeout));
      }
      await process.stdin.close();
    } catch (_) {
      process.kill();
    }
  }

  Stream<Uint8List> _readBody(Process process, StreamIterator<List<int>> cursor, List<int> first, RequestOptions options) async* {
    try {
      if (first.isNotEmpty) {
        yield Uint8List.fromList(first);
      }
      while (await cursor.moveNext().timeout(_positiveTimeout(options.receiveTimeout))) {
        yield Uint8List.fromList(cursor.current);
      }
      if (await process.exitCode != 0) {
        throw _failure(options, 'echInvalidResponse');
      }
    } on TimeoutException {
      exEchStatus.value = ExEchStatus.failed;
      throw _failure(options, 'echTimedOut');
    } finally {
      await cursor.cancel();
      if (_processes.contains(process)) {
        process.kill();
      }
    }
  }

  static Duration _positiveTimeout(Duration? value) => value != null && value > Duration.zero ? value : const Duration(seconds: 30);

  @override
  void close({bool force = false}) {
    for (final process in _processes) {
      process.kill();
    }
    _connections.close();
    _resolverClient.close(force: force);
    _defaultAdapter.close(force: force);
  }
}

class _EchException implements Exception {
  final String code;
  const _EchException(this.code);
}

class _ConcurrentRequests {
  final int limit;
  int _active = 0;
  bool _closed = false;
  final _waiting = <Completer<bool>>[];

  _ConcurrentRequests(this.limit);

  Future<void Function()?> acquire(Future<void>? cancelFuture) async {
    if (_closed) {
      return null;
    }
    if (_active >= limit) {
      final waiter = Completer<bool>();
      _waiting.add(waiter);
      unawaited(cancelFuture?.then<void>((_) {
        if (_waiting.remove(waiter)) {
          waiter.complete(false);
        }
      }));
      if (!await waiter.future) {
        return null;
      }
    } else {
      _active++;
    }
    return () {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeAt(0).complete(true);
      }
    };
  }

  void close() {
    _closed = true;
    for (final waiter in _waiting) {
      waiter.complete(false);
    }
    _waiting.clear();
  }
}
