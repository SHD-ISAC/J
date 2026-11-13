import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:logger/logger.dart';

void main() {
  test('the master switch prevents file logging even with verbose logging enabled', () async {
    final directory = await Directory.systemTemp.createTemp('jhentai-test-logs');
    final logService = LogService()..logDirPath = '${directory.path}/logs';
    final logging = advancedSetting.enableLogging.value;
    final verbose = advancedSetting.enableVerboseLogging.value;
    addTearDown(() async {
      advancedSetting.enableLogging.value = logging;
      advancedSetting.enableVerboseLogging.value = verbose;
      await logService.clear();
      await directory.delete();
    });

    advancedSetting.enableLogging.value = false;
    advancedSetting.enableVerboseLogging.value = true;
    await logService.doAfterBeanReady();
    await logService.info('test message');
    await logService.download('test download');

    expect(await directory.list().toList(), isEmpty);
  });

  test('network and parse error logs contain only the error category', () async {
    final logService = LogService();
    final events = <LogEvent>[];
    final listener = events.add;
    Logger.addLogListener(listener);
    addTearDown(() => Logger.removeLogListener(listener));

    final request = RequestOptions(path: 'https://example.test/', headers: {'cookie': 'sample=value'});
    await logService.error('test request', DioException(requestOptions: request, type: DioExceptionType.badResponse));
    await logService.error('test parsing', const FormatException('Invalid data', 'sample=value'));

    expect(events.map((event) => event.error), [DioExceptionType.badResponse, FormatException]);
  });
}
