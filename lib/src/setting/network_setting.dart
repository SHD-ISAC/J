import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';

import '../service/local_config_service.dart';
import '../service/jh_service.dart';
import '../service/log.dart';

NetworkSetting networkSetting = NetworkSetting();

class NetworkSetting with JHLifeCircleBeanWithConfigStorage implements JHLifeCircleBean {
  Rx<Duration> pageCacheMaxAge = const Duration(hours: 1).obs;
  Rx<Duration> cacheImageExpireDuration = const Duration(days: 7).obs;
  Rx<JProxyType> proxyType = JProxyType.system.obs;
  RxString proxyAddress = 'localhost:1080'.obs;
  RxnString proxyUsername = RxnString();
  RxnString proxyPassword = RxnString();
  final RxBool allowProxyDirectFallback = false.obs;
  final RxBool enableExEch = false.obs;
  String systemProxyAddress = '';
  RxInt connectTimeout = 6000.obs;
  RxInt receiveTimeout = 6000.obs;

  @override
  ConfigEnum get configEnum => ConfigEnum.networkSetting;

  @override
  void applyBeanConfig(String configString) {
    Map map = jsonDecode(configString);

    pageCacheMaxAge.value = Duration(milliseconds: map['pageCacheMaxAge'] ?? pageCacheMaxAge.value.inMilliseconds);
    cacheImageExpireDuration.value = Duration(milliseconds: map['cacheImageExpireDuration'] ?? cacheImageExpireDuration.value.inMilliseconds);
    proxyType.value = JProxyType.values[map['proxyType'] ?? proxyType.value.index];
    proxyAddress.value = map['proxyAddress'] ?? proxyAddress.value;
    proxyUsername.value = map['proxyUsername'] ?? proxyUsername.value;
    proxyPassword.value = map['proxyPassword'] as String?;
    allowProxyDirectFallback.value = map['allowProxyDirectFallback'] == true;
    enableExEch.value = (Platform.isMacOS || Platform.isLinux) && map['enableExEch'] == true;
    connectTimeout.value = map['connectTimeout'] ?? connectTimeout.value;
    receiveTimeout.value = map['receiveTimeout'] ?? receiveTimeout.value;
  }

  @override
  String toConfigString() {
    return jsonEncode({
      'pageCacheMaxAge': pageCacheMaxAge.value.inMilliseconds,
      'cacheImageExpireDuration': cacheImageExpireDuration.value.inMilliseconds,
      'proxyType': proxyType.value.index,
      'proxyAddress': proxyAddress.value,
      'proxyUsername': proxyUsername.value,
      'proxyPassword': proxyPassword.value,

      'allowProxyDirectFallback': allowProxyDirectFallback.value,
      'enableExEch': enableExEch.value,
      'connectTimeout': connectTimeout.value,
      'receiveTimeout': receiveTimeout.value,
    });
  }

  @override
  Future<void> doInitBean() async {}

  @override
  void doAfterBeanReady() {}

  Future<void> savePageCacheMaxAge(Duration pageCacheMaxAge) async {
    log.debug('savePageCacheMaxAge:$pageCacheMaxAge');
    this.pageCacheMaxAge.value = pageCacheMaxAge;
    await saveBeanConfig();
  }

  Future<void> saveCacheImageExpireDuration(Duration cacheImageExpireDuration) async {
    log.debug('saveCacheImageExpireDuration:$cacheImageExpireDuration');
    this.cacheImageExpireDuration.value = cacheImageExpireDuration;
    await saveBeanConfig();
  }

  Future<void> saveProxy(JProxyType proxyType, String proxyAddress, String? proxyUsername, String? proxyPassword) async {
    final address = proxyAddress.trim();
    if (proxyType != JProxyType.system && proxyType != JProxyType.direct) {
      final uri = Uri.tryParse('http://$address');
      if (uri == null ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          !uri.hasPort ||
          uri.port < 1 ||
          uri.port > 65535 ||
          address.contains(RegExp(r'[;\s]'))) {
        throw const FormatException('Invalid proxy endpoint');
      }
    }
    if ((proxyUsername?.contains(RegExp(r'[:@;\s]')) ?? false) ||
        (proxyPassword?.contains(RegExp(r'[@;\s]')) ?? false)) {
      throw const FormatException('Invalid proxy credentials');
    }
    final config = jsonDecode(toConfigString()) as Map<String, dynamic>;
    config['proxyType'] = proxyType.index;
    config['proxyAddress'] = address;
    config['proxyUsername'] = proxyUsername;
    config['proxyPassword'] = proxyPassword;
    await localConfigService.write(configKey: configEnum, value: jsonEncode(config), replaceCredentials: true);
    this.proxyAddress.value = address;
    this.proxyUsername.value = proxyUsername;
    this.proxyPassword.value = proxyPassword;
    this.proxyType.value = proxyType;
  }

  Future<void> saveEnableExEch(bool value) async {
    enableExEch.value = value;
    await saveBeanConfig();
  }

  Future<void> saveProxyDirectFallback(bool value) async {
    allowProxyDirectFallback.value = value;
    await saveBeanConfig();
  }

  Future<void> saveConnectTimeout(int connectTimeout) async {
    log.debug('saveConnectTimeout:$connectTimeout');
    this.connectTimeout.value = connectTimeout;
    await saveBeanConfig();
  }

  Future<void> saveReceiveTimeout(int receiveTimeout) async {
    log.debug('saveReceiveTimeout:$receiveTimeout');
    this.receiveTimeout.value = receiveTimeout;
    await saveBeanConfig();
  }
}

enum JProxyType { system, http, socks5, socks4, direct }
