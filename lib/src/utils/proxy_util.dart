import 'package:flutter/cupertino.dart';
import 'package:get/get_utils/src/platform/platform.dart';
import 'package:http_proxy/http_proxy.dart';
import 'package:jhentai/src/utils/string_uril.dart';
import 'package:system_network_proxy/system_network_proxy.dart';

import '../setting/network_setting.dart';
import '../enum/config_enum.dart';
import '../service/local_config_service.dart';

Future<String> getSystemProxyAddress() async {
  String systemProxyAddress = '';

  if (GetPlatform.isDesktop) {
    SystemNetworkProxy.init();
    systemProxyAddress = await SystemNetworkProxy.getProxyServer();
  }
  if (GetPlatform.isMobile) {
    HttpProxy httpProxy = await HttpProxy.createHttpProxy();
    if (!isEmptyOrNull(httpProxy.host) && !isEmptyOrNull(httpProxy.port)) {
      systemProxyAddress = '${httpProxy.host}:${httpProxy.port}';
    }
  }

  return systemProxyAddress;
}

String Function(Uri) findProxySettingFunc(ValueGetter<String> systemProxyAddress) {
  String configProxyAddress() {
    if (localConfigService.credentialsAreLocked(ConfigEnum.networkSetting)) {
      throw const SecureConfigException();
    }
    String configAddress;
    if (isEmptyOrNull(networkSetting.proxyUsername.value?.trim()) && isEmptyOrNull(networkSetting.proxyPassword.value?.trim())) {
      configAddress = networkSetting.proxyAddress.value;
    } else {
      configAddress = '${networkSetting.proxyUsername.value ?? ''}:${networkSetting.proxyPassword.value ?? ''}@${networkSetting.proxyAddress.value}';
    }
    return configAddress;
  }

  return (_) {
    final fallback = networkSetting.allowProxyDirectFallback.value ? '; DIRECT' : '';
    switch (networkSetting.proxyType.value) {
      case JProxyType.system:
        return isEmptyOrNull(systemProxyAddress.call()) ? 'DIRECT' : 'PROXY ${systemProxyAddress.call()}; DIRECT';
      case JProxyType.http:
        return 'PROXY ${configProxyAddress()}$fallback';
      case JProxyType.socks5:
        return 'SOCKS5 ${configProxyAddress()}$fallback';
      case JProxyType.socks4:
        return 'SOCKS4 ${configProxyAddress()}$fallback';
      case JProxyType.direct:
        return 'DIRECT';
    }
  };
}
