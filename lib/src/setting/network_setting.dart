import 'dart:convert';

import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/network/eh_request.dart';

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
    proxyPassword.value = map['proxyPassword'] ?? proxyPassword.value;
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
    log.debug('Proxy type: $proxyType');
    this.proxyType.value = proxyType;
    this.proxyAddress.value = proxyAddress;
    this.proxyUsername.value = proxyUsername;
    this.proxyPassword.value = proxyPassword;
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
