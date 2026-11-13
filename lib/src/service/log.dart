import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

import '../exception/upload_exception.dart';
import 'jh_service.dart';
import '../utils/byte_util.dart';

LogService log = LogService();

class LogService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  String? logDirPath;

  Logger? _consoleLogger;
  Logger? _verboseFileLogger;
  Logger? _warningFileLogger;
  Logger? _downloadFileLogger;
  bool _settingsLoaded = false;
  Future<void> _fileOperations = Future<void>.value();

  LogPrinter devPrinter = PrettyPrinter(stackTraceBeginIndex: 0, methodCount: 6, levelEmojis: {Level.trace: '✔ '});
  LogPrinter prodPrinterWithBox = PrettyPrinter(stackTraceBeginIndex: 0, methodCount: 6, colors: false, printTime: true, levelEmojis: {Level.trace: '✔ '});
  LogPrinter prodPrinterWithoutBox = PrettyPrinter(
    stackTraceBeginIndex: 0,
    methodCount: 6,
    colors: false,
    noBoxingByDefault: true,
    levelEmojis: {Level.trace: '✔ '},
  );

  @override
  List<JHLifeCircleBean> get initDependencies => [pathService];

  @override
  Future<void> doInitBean() async {
    logDirPath = path.join(pathService.getVisibleDir().path, 'logs');

    PlatformDispatcher.instance.onError = (error, stack) {
      if (error is NotUploadException) {
        return true;
      }

      log.error('Global Error', error, stack);
      return false;
    };

    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exception is NotUploadException) {
        return;
      }

      log.error('Global Error', details.exception, details.stack);
    };
  }

  @override
  Future<void> doAfterBeanReady() async {
    _settingsLoaded = true;
  }

  /// For actions that print params
  Future<void> trace(Object msg, [bool withStack = false]) {
    return _write(Level.trace, msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  /// For actions that is invisible to user
  Future<void> debug(Object msg, [bool withStack = false]) {
    return _write(Level.debug, msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  /// For actions that is visible to user
  Future<void> info(Object msg, [bool withStack = false]) {
    return _write(Level.info, msg, stackTrace: withStack ? null : StackTrace.empty);
  }

  Future<void> warning(Object msg, [Object? error, bool withStack = false]) {
    return _write(Level.warning, msg, error: error, stackTrace: withStack ? null : StackTrace.empty);
  }

  Future<void> error(Object msg, [Object? error, StackTrace? stackTrace]) {
    return _write(Level.error, msg, error: error, stackTrace: stackTrace);
  }

  Future<void> download(Object msg) {
    return _write(Level.trace, msg, stackTrace: StackTrace.empty, download: true);
  }

  Future<void> _write(Level level, Object msg, {Object? error, StackTrace? stackTrace, bool download = false}) async {
    final message = _safeLogValue(msg);
    final detail = _safeLogValue(error);
    final console = _consoleLogger ??= Logger(printer: devPrinter);
    await console.init;
    console.log(level, message, error: detail, stackTrace: stackTrace);

    if (!_settingsLoaded || advancedSetting.enableLogging.isFalse || logDirPath == null) {
      return;
    }
    try {
      await _withLogFiles(() async {
        if (advancedSetting.enableLogging.isFalse) {
          return;
        }
        await _initFileLoggers();
        if (advancedSetting.enableLogging.isFalse) {
          return;
        }

        if (download) {
          if (advancedSetting.enableVerboseLogging.isTrue) {
            _downloadFileLogger?.log(level, message, stackTrace: stackTrace);
          }
          return;
        }
        _verboseFileLogger!.log(level, message, error: detail, stackTrace: stackTrace);
        if (advancedSetting.enableVerboseLogging.isTrue && level.index >= Level.warning.index) {
          _warningFileLogger?.log(level, message, error: detail, stackTrace: stackTrace);
        }
      });
    } on FileSystemException catch (e) {
      console.w('Unable to write application logs', error: e.runtimeType);
    }
  }

  Object? _safeLogValue(Object? value) {
    return switch (value) {
      DioException(:final type) => type,
      FormatException() => value.runtimeType,
      HttpException() => value.runtimeType,
      _ => value,
    };
  }

  Future<void> uploadError(dynamic throwable, {dynamic stackTrace, Map<String, dynamic>? extraInfos}) async {
    /// sentry is removed
  }

  Future<String> getSize() async {
    final directory = logDirPath;
    if (directory == null) {
      return byte2String(0);
    }
    return compute((String logDirPath) {
      Directory logDirectory = Directory(logDirPath);
      return logDirectory
          .exists()
          .then<int>((exist) {
            if (!exist) {
              return 0;
            }

            return logDirectory.list().where((element) => element is File).fold<int>(0, (bytes, file) => bytes + (file as File).lengthSync());
          })
          .then<String>((totalBytes) => byte2String(totalBytes.toDouble()));
    }, directory);
  }

  Future<void> clear() => _withLogFiles(() async {
    await _verboseFileLogger?.close();
    await _warningFileLogger?.close();
    await _downloadFileLogger?.close();

    _verboseFileLogger = null;
    _warningFileLogger = null;
    _downloadFileLogger = null;

    final directory = logDirPath;
    if (directory != null && await Directory(directory).exists()) {
      await Directory(directory).delete(recursive: true);
    }
  });

  Future<void> _withLogFiles(Future<void> Function() action) {
    final operation = _fileOperations.then((_) => action());
    _fileOperations = operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _initFileLoggers() async {
    if (_verboseFileLogger != null && (advancedSetting.enableVerboseLogging.isFalse || _warningFileLogger != null)) {
      return;
    }
    await Directory(logDirPath!).create(recursive: true);
    String fileName = DateFormat('yyyy-MM-dd_HH-mm-ss').format(DateTime.now());

    _verboseFileLogger ??= Logger(
      printer: HybridPrinter(prodPrinterWithBox, trace: prodPrinterWithoutBox, debug: prodPrinterWithoutBox, info: prodPrinterWithoutBox),
      filter: EHLogFilter(),
      output: FileOutput(file: File(path.join(logDirPath!, '$fileName.log'))),
    );
    if (advancedSetting.enableVerboseLogging.isTrue) {
      _warningFileLogger ??= Logger(
        level: Level.warning,
        printer: prodPrinterWithBox,
        filter: ProductionFilter(),
        output: FileOutput(file: File(path.join(logDirPath!, '${fileName}_error.log'))),
      );
      _downloadFileLogger ??= Logger(
        printer: prodPrinterWithoutBox,
        filter: ProductionFilter(),
        output: FileOutput(file: File(path.join(logDirPath!, '${fileName}_download.log'))),
      );
    }

    await Future.wait([
      _verboseFileLogger!.init,
      if (_warningFileLogger != null) _warningFileLogger!.init,
      if (_downloadFileLogger != null) _downloadFileLogger!.init,
    ]);
  }
}

class EHLogFilter extends LogFilter {
  @override
  bool shouldLog(LogEvent event) {
    if (advancedSetting.enableVerboseLogging.isTrue) {
      return event.level.index >= level!.index;
    }
    return event.level.index >= level!.index && event.level != Level.trace;
  }
}
