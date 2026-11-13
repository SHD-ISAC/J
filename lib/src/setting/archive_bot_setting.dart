import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/local_config_service.dart';

import '../consts/archive_bot_consts.dart';
import '../model/archive_bot_response/archive_resolve_vo.dart';
import '../model/archive_bot_response/balance_vo.dart';
import '../model/archive_bot_response/check_in_vo.dart';
import '../service/jh_service.dart';

ArchiveBotSetting archiveBotSetting = ArchiveBotSetting();

enum ArchiveBotType {
  ehArBot(0),
  archiveAtHome(1),
  ;

  final int code;

  const ArchiveBotType(this.code);

  bool get supportsCheckIn => switch (this) {
        ehArBot => true,
        _ => false,
      };

  String get defaultServerAddress {
    switch (this) {
      case ArchiveBotType.ehArBot:
        return ArchiveBotConsts.defaultEhArBotServerAddress;
      case ArchiveBotType.archiveAtHome:
        return ArchiveBotConsts.defaultArchiveAtHomeServerAddress;
    }
  }

  BalanceVO parseBalance(Map<String, dynamic> data) {
    switch (this) {
      case ArchiveBotType.ehArBot:
        return BalanceVO.fromEhArBotResponse(data);
      case ArchiveBotType.archiveAtHome:
        return BalanceVO.fromArchiveAtHomeResponse(data);
    }
  }

  CheckInVO parseCheckIn(Map<String, dynamic> data) {
    switch (this) {
      case ArchiveBotType.ehArBot:
        return CheckInVO.fromEhArBotResponse(data);
      case ArchiveBotType.archiveAtHome:
        return CheckInVO.fromArchiveAtHomeResponse(data);
    }
  }

  ArchiveResolveVO parseResolve(Map<String, dynamic> data) {
    switch (this) {
      case ArchiveBotType.ehArBot:
        return ArchiveResolveVO.fromEhArBotResponse(data);
      case ArchiveBotType.archiveAtHome:
        return ArchiveResolveVO.fromArchiveAtHomeResponse(data);
    }
  }

  static ArchiveBotType fromCode(int code) {
    return ArchiveBotType.values.firstWhere(
      (e) => e.code == code,
      orElse: () => ArchiveBotType.ehArBot,
    );
  }
}

class ArchiveBotSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  final Rx<ArchiveBotType> botType = ArchiveBotType.ehArBot.obs;

  /// Only used when botType == ehArBot
  final RxnString apiAddress = RxnString(ArchiveBotConsts.defaultEhArBotServerAddress);

  final RxnString apiKey = RxnString(null);

  /// Last source (official / bot) the user picked in the archive download dialog
  final RxBool preferBotSource = false.obs;

  bool get isReady => apiKey.value != null && apiAddress.value != null;

  @override
  ConfigEnum get configEnum => ConfigEnum.archiveBotSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);
    apiKey.value = map['apiKey'];

    if (map['botType'] != null) {
      botType.value = ArchiveBotType.fromCode(map['botType'] as int);
    }

    apiAddress.value = map['apiAddress'];

    if (map['preferBotSource'] != null) {
      preferBotSource.value = map['preferBotSource'] as bool;
    }
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'botType': botType.value.code,
      'apiAddress': apiAddress.value,
      'apiKey': apiKey.value,
      'preferBotSource': preferBotSource.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> saveConfig({
    required ArchiveBotType type,
    String? address,
    String? key,
  }) async {
    final endpoint = address?.trim();
    if (endpoint != null && key != null) {
      final uri = Uri.tryParse(endpoint);
      if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
        throw const FormatException('Invalid archive bot HTTPS endpoint');
      }
    }
    final config = {
      'botType': type.code,
      'apiAddress': endpoint,
      'apiKey': key,
      'preferBotSource': preferBotSource.value,
    };
    await localConfigService.write(configKey: configEnum, value: jsonEncode(config), replaceCredentials: true);
    botType.value = type;
    apiAddress.value = endpoint;
    apiKey.value = key;
  }

  Future<void> savePreferBotSource(bool value) async {
    log.debug('savePreferBotSource: $value');
    preferBotSource.value = value;
    await saveBeanConfig();
  }
}
