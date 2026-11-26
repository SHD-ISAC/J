import 'dart:convert';

import 'package:dio/dio.dart';

const exEchHost = 'exhentai.org';

typedef ExEchConfig = ({String encoded, DateTime expires});

const _resolvers = [
  'https://dns.google/resolve',
  'https://cloudflare-dns.com/dns-query',
];

final _serviceRecord = RegExp(r'^([1-9][0-9]*)\s+\.\s+');
final _echParameter = RegExp(r'(?:^|\s)ech=(?:"([A-Za-z0-9+/=]+)"|([A-Za-z0-9+/=]+))(?=\s|$)');
final _portParameter = RegExp(r'(?:^|\s)port=(\S+)');

Future<ExEchConfig?> resolveExEchConfig(Dio client) async {
  for (final resolver in _resolvers) {
    try {
      final response = await client.get<String>(
        resolver,
        queryParameters: {'name': exEchHost, 'type': 65},
        options: Options(
          headers: {'accept': 'application/dns-json'},
          responseType: ResponseType.plain,
          followRedirects: false,
        ),
      );
      final body = response.data;
      if (body == null || body.length > 64 * 1024) {
        continue;
      }
      final config = _readConfig(jsonDecode(body));
      if (config != null) {
        return config;
      }
    } on DioException {
      continue;
    } on FormatException {
      continue;
    }
  }
  return null;
}

ExEchConfig? _readConfig(dynamic data) {
  if (data is! Map || data['Status'] != 0 || data['TC'] == true || data['Answer'] is! List) {
    return null;
  }
  ExEchConfig? best;
  var bestPriority = 65536;
  for (final answer in (data['Answer'] as List).whereType<Map>()) {
    final owner = answer['name'];
    final record = answer['data'];
    if (answer['type'] != 65 ||
        owner is! String ||
        owner.toLowerCase().replaceFirst(RegExp(r'\.$'), '') != exEchHost ||
        record is! String) {
      continue;
    }
    // The helper connects to the original origin on port 443. Accept service
    // records for that endpoint and keep the lowest advertised priority.
    final service = _serviceRecord.firstMatch(record);
    final priority = int.tryParse(service?.group(1) ?? '');
    if (priority == null || priority >= bestPriority) {
      continue;
    }
    final parameters = record.substring(service!.end);
    final port = _portParameter.firstMatch(parameters)?.group(1);
    if (port != null && port != '443' && port != '"443"') {
      continue;
    }
    final parameter = _echParameter.firstMatch(parameters);
    final encoded = parameter?.group(1) ?? parameter?.group(2);
    if (encoded == null || encoded.length > 8192) {
      continue;
    }
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length < 6 || (bytes[0] << 8 | bytes[1]) != bytes.length - 2) {
        continue;
      }
      final ttl = answer['TTL'];
      final seconds = ttl is int ? ttl.clamp(0, 3600) : 0;
      best = (encoded: base64Encode(bytes), expires: DateTime.now().add(Duration(seconds: seconds)));
      bestPriority = priority;
    } on FormatException {
      continue;
    }
  }
  return best;
}
