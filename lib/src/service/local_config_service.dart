import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/jh_service.dart';

import '../database/database.dart';

class LocalConfig {
  ConfigEnum configKey;
  String subConfigKey;
  String value;
  String utime;

  LocalConfig({
    required this.configKey,
    required this.subConfigKey,
    required this.value,
    required this.utime,
  });

  Map<String, dynamic> toJson() {
    return {
      "configKey": this.configKey.key,
      "subConfigKey": this.subConfigKey,
      "value": this.value,
      "utime": this.utime,
    };
  }

  factory LocalConfig.fromJson(Map<String, dynamic> json) {
    return LocalConfig(
      configKey: ConfigEnum.from(json["configKey"]),
      subConfigKey: json["subConfigKey"],
      value: json["value"],
      utime: json["utime"],
    );
  }
}

LocalConfigService localConfigService = LocalConfigService();

class SecureConfigException implements Exception {
  const SecureConfigException();

  @override
  String toString() => 'Unable to access the system credential store';
}

class LocalConfigService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static const String defaultSubConfigKey = '';
  static const _storage = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));
  final AppDb? _database;

  LocalConfigService({AppDb? database}) : _database = database;

  AppDb get _db => _database ?? appDb;
  static const _cookieMarker = '{"systemCredentialStore":true}';
  final _lockedCredentials = <ConfigEnum>{};

  bool credentialsAreLocked(ConfigEnum key) => _lockedCredentials.contains(key);
  static const _secretFields = <ConfigEnum, Set<String>>{
    ConfigEnum.userSetting: {'ipbPassHash', 'ipbMemberId'},
    ConfigEnum.networkSetting: {'proxyPassword', 'proxyUsername'},
    ConfigEnum.archiveBotSetting: {'apiKey'},
    ConfigEnum.securitySetting: {'encryptedPassword'},
  };

  Future<void> _secureOperations = Future<void>.value();

  bool _isProtected(ConfigEnum key, String subKey) {
    return (Platform.isMacOS || Platform.isLinux) && subKey == defaultSubConfigKey && (key == ConfigEnum.ehCookie || _secretFields.containsKey(key));
  }

  String _secureKey(ConfigEnum key) => 'hardened:${key.key}';

  Future<T> _withSecureStorage<T>(Future<T> Function() operation) {
    final result = _secureOperations.then((_) => operation());
    _secureOperations = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<T> _accessSystemStore<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } catch (_) {
      throw const SecureConfigException();
    }
  }

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {}

  Future<int> write({
    required ConfigEnum configKey,
    String subConfigKey = defaultSubConfigKey,
    required String value,
    bool replaceCredentials = false,
  }) {
    if (_isProtected(configKey, subConfigKey)) {
      return _withSecureStorage(() => _writeProtected(configKey, value, replaceCredentials: replaceCredentials));
    }
    return _writeRow(configKey, subConfigKey, value);
  }

  Future<int> _writeProtected(ConfigEnum key, String value, {bool replaceCredentials = false}) async {
    String publicValue;
    String? secretValue;
    if (key == ConfigEnum.ehCookie) {
      publicValue = _cookieMarker;
      secretValue = value;
    } else {
      final config = jsonDecode(value) as Map<String, dynamic>;
      final secrets = <String, dynamic>{};
      for (final field in _secretFields[key]!) {
        final secret = config.remove(field);
        if (secret != null) {
          secrets[field] = secret;
        }
      }
      publicValue = jsonEncode(config);
      secretValue = secrets.isEmpty ? null : jsonEncode(secrets);
    }
    final storageKey = _secureKey(key);
    if (secretValue != null) {
      await _accessSystemStore(() => _storage.write(key: storageKey, value: secretValue));
      _lockedCredentials.remove(key);
    }
    final existing = await _readRow(key, defaultSubConfigKey);
    final wasProtected = existing != null && _hasCredentialMarker(existing);
    if (secretValue == null && wasProtected && replaceCredentials) {
      await _accessSystemStore(() => _storage.delete(key: storageKey));
      _lockedCredentials.remove(key);
    }
    if (key != ConfigEnum.ehCookie && (secretValue != null || (wasProtected && !replaceCredentials))) {
      final config = jsonDecode(publicValue) as Map<String, dynamic>;
      publicValue = jsonEncode(config..['systemCredentialStore'] = true);
    }
    return _writeRow(key, defaultSubConfigKey, publicValue);
  }

  bool _hasCredentialMarker(String value) {
    final decoded = jsonDecode(value);
    return decoded is Map && decoded['systemCredentialStore'] == true;
  }

  Future<int> _writeRow(ConfigEnum configKey, String subConfigKey, String value) {
    return _db.managers.localConfig.create(
      (l) => l(configKey: configKey.key, subConfigKey: subConfigKey, value: value, utime: DateTime.now().toString()),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<void> batchWrite(List<LocalConfigCompanion> localConfigs) async {
    return _db.managers.localConfig.bulkCreate(
      (l) => localConfigs
          .map((i) => l(
                configKey: i.configKey.value,
                subConfigKey: i.subConfigKey.value,
                value: i.value.value,
                utime: DateTime.now().toString(),
              ))
          .toList(),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<String?> read({required ConfigEnum configKey, String subConfigKey = defaultSubConfigKey}) {
    if (_isProtected(configKey, subConfigKey)) {
      return _withSecureStorage(() => _readProtected(configKey));
    }
    return _readRow(configKey, subConfigKey);
  }

  Future<String?> _readProtected(ConfigEnum key) async {
    final value = await _readRow(key, defaultSubConfigKey);
    if (value == null) {
      return null;
    }
    final storageKey = _secureKey(key);
    if (key == ConfigEnum.ehCookie) {
      if (value == _cookieMarker) {
        try {
          final stored = await _accessSystemStore(() => _storage.read(key: storageKey));
          _lockedCredentials.remove(key);
          return stored;
        } on SecureConfigException {
          _lockedCredentials.add(key);
          return null;
        }
      }
      if (jsonDecode(value) is List) {
        try {
          await _writeProtected(key, value);
        } on SecureConfigException {
          _lockedCredentials.add(key);
          return null;
        }
      }
      return value;
    }

    final config = jsonDecode(value) as Map<String, dynamic>;
    final fields = _secretFields[key]!;
    if (fields.any((field) => config.containsKey(field))) {
      try {
        await _writeProtected(key, value);
        return value;
      } on SecureConfigException {
        _lockedCredentials.add(key);
        for (final field in fields) {
          config.remove(field);
        }
        return jsonEncode(config);
      }
    }
    if (config.remove('systemCredentialStore') == true) {
      String? stored;
      try {
        stored = await _accessSystemStore(() => _storage.read(key: storageKey));
      } on SecureConfigException {
        _lockedCredentials.add(key);
        return jsonEncode(config);
      }
      if (stored != null) {
        _lockedCredentials.remove(key);
        final secrets = jsonDecode(stored) as Map<String, dynamic>;
        for (final field in fields) {
          if (secrets.containsKey(field)) {
            config[field] = secrets[field];
          }
        }
      }
    }
    return jsonEncode(config);
  }

  Future<String?> _readRow(ConfigEnum configKey, String subConfigKey) {
    return _db.managers.localConfig
        .filter((config) => config.configKey.equals(configKey.key) & config.subConfigKey.equals(subConfigKey))
        .getSingleOrNull()
        .then((value) => value?.value);
  }

  Future<List<LocalConfig>> readWithAllSubKeys({required ConfigEnum configKey}) {
    return _db.managers.localConfig.filter((config) => config.configKey.equals(configKey.key)).get().then((value) {
      return value
          .map((e) => LocalConfig(
                configKey: ConfigEnum.from(e.configKey),
                subConfigKey: e.subConfigKey,
                value: e.value,
                utime: e.utime,
              ))
          .toList();
    });
  }

  Future<bool> delete({required ConfigEnum configKey, String subConfigKey = defaultSubConfigKey}) {
    if (_isProtected(configKey, subConfigKey)) {
      return _withSecureStorage(() async {
        final value = await _readRow(configKey, subConfigKey);
        if (value != null) {
          if (_hasCredentialMarker(value)) {
            await _accessSystemStore(() => _storage.delete(key: _secureKey(configKey)));
          }
        }
        _lockedCredentials.remove(configKey);
        return _deleteRow(configKey, subConfigKey);
      });
    }
    return _deleteRow(configKey, subConfigKey);
  }

  Future<bool> _deleteRow(ConfigEnum configKey, String subConfigKey) {
    return _db.managers.localConfig
        .filter((config) => config.configKey.equals(configKey.key) & config.subConfigKey.equals(subConfigKey))
        .delete()
        .then((value) => value > 0);
  }
}
