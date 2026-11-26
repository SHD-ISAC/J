import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/network/ex_ech_config.dart';

const _config = 'AEX+DQBBggAgACALe8fZlz9Kbm1CJwrCi6OKEg8OOarcIjJBVMWd16RufAAEAAEAAQASY2xvdWRmbGFyZS1lY2guY29tAAA=';

void main() {
  test('reads the original resolver without sending a second DNS query', () async {
    final adapter = _ResolverAdapter([
      (status: 200, body: _answer('1 . alpn=h2 ech=$_config'), type: 'application/json'),
    ]);
    final client = Dio()..httpClientAdapter = adapter;
    addTearDown(client.close);

    final config = await resolveExEchConfig(client);

    expect(config?.encoded, _config);
    expect(config!.expires, isAfter(DateTime.now()));
    expect(adapter.hosts, ['dns.google']);
  });

  test('reads the alternative DNS JSON media type when the primary resolver fails', () async {
    final adapter = _ResolverAdapter([
      (status: 503, body: 'DNS service unavailable', type: 'text/plain'),
      (status: 200, body: _answer('1 . alpn=h3,h2 ech="$_config"'), type: 'application/dns-json'),
    ]);
    final client = Dio()..httpClientAdapter = adapter;
    addTearDown(client.close);

    expect((await resolveExEchConfig(client))?.encoded, _config);
    expect(adapter.hosts, ['dns.google', 'cloudflare-dns.com']);
  });

  test('skips malformed configs and service records for other ports', () async {
    final adapter = _ResolverAdapter([
      (status: 200, body: _answer('1 . ech=AAAA'), type: 'application/json'),
      (
        status: 200,
        body: _answer('1 . port=8443 ech=$_config'),
        type: 'application/dns-json',
      ),
    ]);
    final client = Dio()..httpClientAdapter = adapter;
    addTearDown(client.close);

    expect(await resolveExEchConfig(client), isNull);
    expect(adapter.hosts, ['dns.google', 'cloudflare-dns.com']);
  });
}

String _answer(String data) => jsonEncode({
      'Status': 0,
      'Answer': [
        {'name': '$exEchHost.', 'type': 65, 'TTL': 300, 'data': data},
      ],
    });

class _ResolverAdapter implements HttpClientAdapter {
  final List<({int status, String body, String type})> answers;
  final hosts = <String>[];

  _ResolverAdapter(this.answers);

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    expect(options.uri.scheme, 'https');
    expect(options.uri.queryParameters, {'name': exEchHost, 'type': '65'});
    expect(options.followRedirects, isFalse);
    final answer = answers[hosts.length];
    hosts.add(options.uri.host);
    return ResponseBody.fromString(answer.body, answer.status, headers: {
      Headers.contentTypeHeader: [answer.type],
    });
  }

  @override
  void close({bool force = false}) {}
}
