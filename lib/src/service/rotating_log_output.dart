import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';
import 'package:path/path.dart' as path;

class RotatingLogOutput extends LogOutput {
  final Directory directory;
  final String name;
  final int maxBytes;
  final int maxFiles;
  final Duration maxAge;
  late final File _file;
  int _size = 0;
  bool _reportedFailure = false;
  DateTime? _changedAt;

  RotatingLogOutput(
    this.directory,
    this.name, {
    this.maxBytes = 1024 * 1024,
    this.maxFiles = 5,
    this.maxAge = const Duration(days: 7),
  });

  @override
  Future<void> init() async {
    _file = File(path.join(directory.path, '$name.log'));
    if (await _file.exists()) {
      final stat = await _file.stat();
      _changedAt = stat.modified;
      _size = stat.size;
    }
    _removeExpiredActiveFile(DateTime.now());
    _prune();
  }

  @override
  void output(OutputEvent event) {
    try {
      final now = DateTime.now();
      _removeExpiredActiveFile(now);
      final eventBytes = utf8.encode('${event.lines.join('\n')}\n');
      if (eventBytes.length > maxBytes) {
        return;
      }
      if (_size + eventBytes.length > maxBytes && _file.existsSync()) {
        _file.renameSync(path.join(directory.path, '$name-${DateTime.now().microsecondsSinceEpoch}.log'));
        _size = 0;
        _prune();
      }
      _file.writeAsBytesSync(eventBytes, mode: FileMode.append);
      _size += eventBytes.length;
      _changedAt = now;
      _reportedFailure = false;
    } on FileSystemException {
      if (!_reportedFailure) {
        _reportedFailure = true;
        stderr.writeln('Unable to append to the application log');
      }
    }
  }

  void _removeExpiredActiveFile(DateTime now) {
    final changedAt = _changedAt;
    if (changedAt != null && now.difference(changedAt) > maxAge && _file.existsSync()) {
      _file.deleteSync();
      _changedAt = null;
      _size = 0;
    }
  }

  void _prune() {
    final now = DateTime.now();
    final files = directory
        .listSync(followLinks: false)
        .whereType<File>()
        .where((file) => path.basename(file.path).startsWith('$name-') && file.path.endsWith('.log'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (int index = 0; index < files.length; index++) {
      final file = files[index];
      if (index >= maxFiles - 1 || now.difference(file.lastModifiedSync()) > maxAge) {
        file.deleteSync();
      }
    }
  }
}
