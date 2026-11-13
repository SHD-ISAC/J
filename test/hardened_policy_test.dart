import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:j_downloader/j_downloader.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/database/database.dart' show AppDb;
import 'package:jhentai/src/network/eh_cache_manager.dart';
import 'package:jhentai/src/network/eh_cookie_manager.dart';
import 'package:jhentai/src/network/hardened_update.dart';
import 'package:jhentai/src/service/cloud_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/rotating_log_output.dart';
import 'package:jhentai/src/setting/network_setting.dart';
import 'package:jhentai/src/utils/app_pin.dart';
import 'package:jhentai/src/utils/proxy_util.dart';
import 'package:jhentai/src/utils/version_util.dart';
import 'package:logger/logger.dart';

void main() {
  test('backup rows are limited to valid reading-progress records', () {
    final expected = {'configKey': 'readIndexRecord', 'subConfigKey': '37', 'value': '2'};
    expect(CloudConfigService.decodeReadProgress([expected]).single.value.value, '2');
    expect(
        () => CloudConfigService.decodeReadProgress([
              expected,
              {...expected, 'value': '-1'}
            ]),
        throwsFormatException);
  });

  test('legacy cached cookie headers are discarded when reading', () {
    final options = RequestOptions(path: 'https://exhentai.org/', responseType: ResponseType.plain);
    final cache = CacheResponse(
      url: options.path,
      cacheKey: 'record',
      content: utf8.encode('cached'),
      headers: utf8.encode(jsonEncode({
        'Set-Cookie': ['sample=value'],
        'content-type': ['text/html']
      })),
      expireDate: DateTime.now().add(const Duration(hours: 1)),
    );
    final response = cache.toResponse(options);
    expect(response.headers[HttpHeaders.setCookieHeader], isNull);
    expect(response.headers.value('content-type'), 'text/html');
  });

  test('live Set-Cookie is omitted when caching the response', () {
    final options = RequestOptions(path: 'https://exhentai.org/', responseType: ResponseType.plain);
    final response = Response<String>(
      requestOptions: options,
      data: 'page',
      headers: Headers.fromMap({
        'set-cookie': ['sample=value'],
        'content-type': ['text/html']
      }),
    );
    final cache = CacheResponse.fromResponse(response, const CacheOptions(expire: Duration(hours: 1)));
    expect(jsonDecode(utf8.decode(cache.headers)), {
      'content-type': ['text/html']
    });
  });

  test('logout discards a live request from the previous session', () async {
    final config = _MemoryConfig();
    final manager = EHCookieManager(config);
    await manager.storeEHCookies([Cookie('ipb_member_id', '123'), Cookie('sample', 'old')]);
    final previous = manager.session;

    await manager.removeAllCookies();
    await manager.storeEHCookies([Cookie('sample', 'stale')], requestSession: previous);
    expect(manager.cookies.map((cookie) => cookie.name), unorderedEquals(['nw', 'datatags']));
    expect(config.value, isNull);
  });

  test('desktop credential migration preserves settings and removes legacy plaintext', () async {
    final database = AppDb.withExecutor(NativeDatabase.memory());
    addTearDown(database.close);
    final service = LocalConfigService(database: database);
    FlutterSecureStorage.setMockInitialValues({});
    await database.managers.localConfig.create((row) => row(
          configKey: 'networkSetting',
          subConfigKey: '',
          value: '{"proxyType":2,"proxyPassword":"example-password"}',
          utime: '2000-01-01',
        ));

    final migrated = await service.read(configKey: ConfigEnum.networkSetting);
    expect(jsonDecode(migrated!), {'proxyType': 2, 'proxyPassword': 'example-password'});
    expect((await database.managers.localConfig.getSingle()).value, isNot(contains('example-password')));
    expect(await service.read(configKey: ConfigEnum.networkSetting), migrated);
    expect(await service.delete(configKey: ConfigEnum.networkSetting), isTrue);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
  }, skip: !Platform.isLinux && !Platform.isMacOS);

  test('manual proxy permits direct fallback only when explicitly enabled', () {
    final saved = networkSetting.toConfigString();
    addTearDown(() => networkSetting.applyBeanConfig(saved));
    networkSetting.proxyType.value = JProxyType.socks5;
    networkSetting.proxyAddress.value = '127.0.0.1:1080';
    networkSetting.allowProxyDirectFallback.value = false;
    final find = findProxySettingFunc(() => '');
    final uri = Uri.parse('https://example.test');
    expect(find(uri), 'SOCKS5 127.0.0.1:1080');
    networkSetting.allowProxyDirectFallback.value = true;
    expect(find(uri), 'SOCKS5 127.0.0.1:1080; DIRECT');
    expect(ProxyConfig.toFindProxy(ProxyConfig(type: ProxyType.http, address: '127.0.0.1:8080'))(uri), 'PROXY 127.0.0.1:8080');
  });

  test('version and platform asset identify a hardened update', () {
    expect(compareBuildVersions('8.0.18+342', '8.0.18+343'), lessThan(0));
    final artifacts = {
      'artifacts': [
        {'id': 194, 'name': 'JHenTai-Hardened-Linux-x64-8.0.18+999', 'expired': true},
        {'id': 195, 'name': 'JHenTai-Hardened-Linux-x64-8.0.18+343', 'expired': false},
      ],
    };
    final update = HardenedUpdate.findLatest(artifacts, runId: 123, platform: 'Linux-x64');
    expect(update?.version, '8.0.18+343');
    expect(update?.page.toString(), 'https://github.com/SHD-ISAC/J/actions/runs/123/artifacts/195');
    expect(HardenedUpdate.findLatest(artifacts, runId: 123, platform: 'macOS-arm64'), isNull);
  });

  test('runner acquisition failure can leave both desktop packages usable', () {
    final smokeJob = {
      'name': 'Launch macOS on Apple silicon',
      'conclusion': 'cancelled',
      'steps': <Object>[],
    };
    final jobs = {
      'jobs': [
        {'name': 'Linux x64', 'conclusion': 'success'},
        {'name': 'macOS arm64', 'conclusion': 'success'},
        smokeJob,
      ],
    };
    expect(HardenedUpdate.completedBuildsWithUnstartedSmoke(jobs), isTrue);
    smokeJob['steps'] = [{'name': 'Verify and start the packaged app', 'conclusion': 'cancelled'}];
    expect(HardenedUpdate.completedBuildsWithUnstartedSmoke(jobs), isFalse);
    smokeJob['conclusion'] = 'failure';
    smokeJob['steps'] = [];
    expect(HardenedUpdate.completedBuildsWithUnstartedSmoke(jobs), isFalse);
  });

  test('logs rotate and prune expired files', () async {
    final dir = await Directory.systemTemp.createTemp('jhentai-log-test');
    addTearDown(() => dir.delete(recursive: true));
    final expired = await File('${dir.path}/log-0000.log').writeAsString('old');
    await expired.setLastModified(DateTime.now().subtract(const Duration(days: 8)));
    final output = RotatingLogOutput(dir, 'log', maxBytes: 8, maxFiles: 2);
    await output.init();
    expect(await expired.exists(), isFalse);
    for (final event in ['first', 'second', 'third']) {
      output.output(OutputEvent(LogEvent(Level.info, event), [event]));
    }
    final paths = await dir.list().toList();
    expect(paths, hasLength(2));
    expect(await File('${dir.path}/log.log').readAsString(), 'third\n');
  });

  test('app PIN uses distinct salts and verifies only the matching PIN', () async {
    final verifier = await AppPin.hash('123456');
    final another = await AppPin.hash('123456');
    expect(verifier, startsWith('argon2id-v1:'));
    expect(verifier, isNot(another));
    expect(await AppPin.matches('123456', verifier), isTrue);
    expect(await AppPin.matches('654321', verifier), isFalse);
  });
}

class _MemoryConfig extends LocalConfigService {
  String? value;

  @override
  Future<int> write({required ConfigEnum configKey, String subConfigKey = '', required String value, bool replaceCredentials = false}) async {
    this.value = value;
    return 1;
  }

  @override
  Future<bool> delete({required ConfigEnum configKey, String subConfigKey = ''}) async {
    value = null;
    return true;
  }
}
