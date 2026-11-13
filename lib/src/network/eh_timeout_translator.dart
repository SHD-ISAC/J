import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/setting/network_setting.dart';

import 'ex_ech_adapter.dart';

class EHTimeoutTranslator extends Interceptor {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.type == DioExceptionType.connectionTimeout) {
      return handler.next(err.copyWith(message: '${'connectionTimeoutHint'.tr} (${networkSetting.connectTimeout}ms)'));
    }
    if (err.type == DioExceptionType.receiveTimeout) {
      return handler.next(err.copyWith(message: '${'receiveDataTimeoutHint'.tr} (${networkSetting.receiveTimeout}ms)'));
    }
    if (err.type == DioExceptionType.connectionError &&
        !isEchFailure(err) &&
        !networkSetting.allowProxyDirectFallback.value &&
        networkSetting.proxyType.value != JProxyType.system &&
        networkSetting.proxyType.value != JProxyType.direct) {
      return handler.next(err.copyWith(message: 'manualProxyConnectionFailed'.tr));
    }
    handler.next(err);
  }
}
