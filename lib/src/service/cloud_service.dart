import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/config.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/search_history_service.dart';

import '../database/database.dart';
import 'history_service.dart';
import 'jh_service.dart';
import 'local_block_rule_service.dart';

CloudConfigService cloudConfigService = CloudConfigService();

class CloudConfigService with JHLifeCircleBeanErrorCatch implements JHLifeCircleBean {
  static Map<CloudConfigTypeEnum, String> configTypeVersionMap = {
    CloudConfigTypeEnum.readIndexRecord: '1.0.0',
    CloudConfigTypeEnum.quickSearch: '1.0.0',
    CloudConfigTypeEnum.searchHistory: '1.0.0',
    CloudConfigTypeEnum.blockRules: '1.0.0',
    CloudConfigTypeEnum.history: '1.0.0',
  };

  static const int localConfigId = -1;
  static const String localConfigCode = 'local';
  static const String configFileName = 'JHenTaiConfig';

  @override
  Future<void> doInitBean() async {}

  @override
  Future<void> doAfterBeanReady() async {}

  Future<void> importConfigs(List<CloudConfig> configs) async {
    final changes = <Future<void> Function()>[];
    final progressKeys = <String>{};
    final importedTypes = <CloudConfigTypeEnum>{};
    for (final config in configs) {
      if (configTypeVersionMap[config.type] != config.version) {
        throw const FormatException('Unsupported backup version');
      }
      importedTypes.add(config.type);
      final decoded = await isolateService.jsonDecodeAsync(config.config);
      switch (config.type) {
        case CloudConfigTypeEnum.readIndexRecord:
          final records = decodeReadProgress(decoded);
          progressKeys.addAll(records.map((entry) => entry.subConfigKey.value));
          changes.add(() => localConfigService.batchWrite(records));
        case CloudConfigTypeEnum.quickSearch:
          final presets = decoded as Map<String, dynamic>;
          for (final value in presets.values) {
            SearchConfig.fromJson(value as Map<String, dynamic>);
          }
          changes.add(() async {
            await localConfigService.write(configKey: ConfigEnum.quickSearch, value: config.config);
          });
        case CloudConfigTypeEnum.searchHistory:
          (decoded as List).cast<String>().toList();
          changes.add(() async {
            await localConfigService.write(configKey: ConfigEnum.searchHistory, value: config.config);
          });
        case CloudConfigTypeEnum.blockRules:
          final rules = (decoded as List).map((entry) => LocalBlockRule.fromJson(entry)..id = null).toList();
          for (final rule in rules) {
            final result = localBlockRuleService.getHandlerByRule(rule).validateRule(rule);
            if (!result.success || rule.groupId == null) {
              throw const FormatException('Invalid rule in backup');
            }
          }
          final groups = rules.groupListsBy((rule) => rule.groupId!);
          changes.add(() async {
            for (final group in groups.entries) {
              if (!await localBlockRuleService.existsGroup(group.key)) {
                final result = await localBlockRuleService.replaceBlockRulesByGroup(group.key, group.value);
                if (!result.success) {
                  throw const FormatException('Unable to import a block rule group');
                }
              }
            }
          });
        case CloudConfigTypeEnum.history:
          final records = (decoded as List).map((entry) => GalleryHistoryV2Data.fromJson(entry)).toList();
          for (final record in records) {
            GalleryHistoryModel.fromJson(jsonDecode(record.jsonBody) as Map<String, dynamic>);
          }
          changes.add(() async {
            for (final chunk in records.slices(1000)) {
              await GalleryHistoryDao.batchReplaceHistory(chunk);
            }
          });
      }
    }

    await appDb.transaction(() async {
      for (final apply in changes) {
        await apply();
      }
    });
    readProgressService.invalidateImportedProgress(progressKeys);
    if (importedTypes.contains(CloudConfigTypeEnum.quickSearch)) {
      await quickSearchService.refreshBean();
    }
    if (importedTypes.contains(CloudConfigTypeEnum.searchHistory)) {
      await searchHistoryService.refreshBean();
    }
  }

  static List<LocalConfigCompanion> decodeReadProgress(Object? decoded) {
    if (decoded is! List) {
      throw const FormatException('Invalid reading-progress backup');
    }
    return decoded.map((entry) {
      if (entry is! Map<String, dynamic> || entry['configKey'] != ConfigEnum.readIndexRecord.key) {
        throw const FormatException('Invalid reading-progress record');
      }
      final key = entry['subConfigKey'];
      final value = entry['value'];
      if (key is! String || (int.tryParse(key) ?? 0) <= 0 || value is! String || (int.tryParse(value) ?? -1) < 0) {
        throw const FormatException('Invalid reading-progress value');
      }
      return LocalConfigCompanion(
        configKey: Value(ConfigEnum.readIndexRecord.key),
        subConfigKey: Value(key),
        value: Value(value),
      );
    }).toList();
  }

  Future<CloudConfig?> getLocalConfig(CloudConfigTypeEnum type) async {
    String configValue;
    switch (type) {
      case CloudConfigTypeEnum.readIndexRecord:
        List<LocalConfig> readIndexRecords = await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord);
        if (readIndexRecords.isEmpty) {
          return null;
        }
        configValue = await isolateService.jsonEncodeAsync(readIndexRecords);
        break;
      case CloudConfigTypeEnum.quickSearch:
        String? quickSearches = await localConfigService.read(configKey: ConfigEnum.quickSearch);
        if (quickSearches == null) {
          return null;
        }
        configValue = quickSearches;
        break;
      case CloudConfigTypeEnum.searchHistory:
        String? searchHistories = await localConfigService.read(configKey: ConfigEnum.searchHistory);
        if (searchHistories == null) {
          return null;
        }
        configValue = searchHistories;
        break;
      case CloudConfigTypeEnum.blockRules:
        List<LocalBlockRule> blockRules = await localBlockRuleService.getBlockRules();
        configValue = await isolateService.jsonEncodeAsync(blockRules);
        break;
      case CloudConfigTypeEnum.history:
        List<GalleryHistoryV2Data> histories = await historyService.getLatest10000RawHistory();
        configValue = await isolateService.jsonEncodeAsync(histories);
        break;
    }

    return CloudConfig(
      id: localConfigId,
      shareCode: localConfigCode,
      identificationCode: localConfigCode,
      type: type,
      version: CloudConfigService.configTypeVersionMap[type]!,
      config: configValue,
      ctime: DateTime.now(),
    );
  }
}
