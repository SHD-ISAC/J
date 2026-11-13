import 'dart:io';

import 'package:clipboard/clipboard.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:get/get_rx/get_rx.dart';
import 'package:get/get_utils/get_utils.dart';
import 'package:jhentai/src/consts/eh_consts.dart';
import 'package:jhentai/src/extension/dio_exception_extension.dart';
import 'package:jhentai/src/extension/widget_extension.dart';
import 'package:jhentai/src/network/eh_cookie_manager.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/setting/user_setting.dart';
import 'package:jhentai/src/utils/cookie_util.dart';
import 'package:jhentai/src/utils/snack_util.dart';
import 'package:jhentai/src/utils/toast_util.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

import '../../../../exception/eh_site_exception.dart';
import '../../../../network/eh_timeout_translator.dart';
import '../../../../network/ex_ech_adapter.dart';
import '../../../../service/log.dart';
import '../../../../setting/network_setting.dart';

class CookiePage extends StatefulWidget {
  const CookiePage({super.key});

  @override
  State<CookiePage> createState() => _CookiePageState();
}

class _CookiePageState extends State<CookiePage> {
  Dio? _dio;
  LoadingState _refreshIgneousState = LoadingState.idle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text('accountSetting'.tr),
        actions: [
          IconButton(icon: const Icon(Icons.copy), onPressed: _copyCookies),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(top: 12),
        children: ehRequest.cookies
            .map(
              (cookie) => ListTile(
                title: Text(cookie.name),
                subtitle: Text(cookie.value),
                trailing: cookie.name == EHConsts.igneousCookieName
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LoadingStateIndicator(
                            loadingState: _refreshIgneousState,
                            loadingWidgetBuilder: () => const CupertinoActivityIndicator().marginOnly(right: 10),
                            idleWidgetBuilder: () => IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshIgneousCookie),
                            successWidgetSameWithIdle: true,
                            errorWidgetSameWithIdle: true,
                          )
                        ],
                      )
                    : null,
                onTap: () => _copyCookie(cookie),
                dense: true,
              ),
            )
            .toList(),
      ).withListTileTheme(context),
    );
  }

  Future<void> _copyCookie(Cookie cookie) async {
    await FlutterClipboard.copy(CookieUtil.parse2String([cookie]));
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _copyCookies() async {
    await FlutterClipboard.copy(
      CookieUtil.parse2String(
        ehRequest.cookies
            .where(
              (cookie) => cookie.name == 'ipb_member_id' || cookie.name == 'ipb_pass_hash' || cookie.name == 'igneous',
            )
            .toList(),
      ),
    );
    toast('hasCopiedToClipboard'.tr);
  }

  Future<void> _refreshIgneousCookie() async {
    if (!userSetting.hasLoggedIn()) {
      return;
    }

    await _initDio();

    if (_refreshIgneousState == LoadingState.loading) {
      return;
    }

    setStateSafely(() {
      _refreshIgneousState = LoadingState.loading;
    });

    try {
      final session = ehRequest.cookieSession;
      Response response = await _dio!.request(
        EHConsts.EXIndex,
        options: Options(headers: {
          'cookie': CookieUtil.parse2String(
            [
              Cookie('ipb_member_id', userSetting.ipbMemberId.value.toString()),
              Cookie('ipb_pass_hash', userSetting.ipbPassHash.value!),
            ],
          )
        }),
      );

      log.info('Refresh igneous cookie response received');

      if (EHCookieManager.isTrustedResponse(response)) {
        final cookies = CookieUtil.parseSetCookieHeaders(response.headers[HttpHeaders.setCookieHeader] ?? []);
        for (final cookie in cookies) {
          if (cookie.name == EHConsts.igneousCookieName && cookie.value != 'mystery') {
            if (session != ehRequest.cookieSession) {
              setStateSafely(() => _refreshIgneousState = LoadingState.idle);
              return;
            }
            await ehRequest.storeEHCookies([Cookie(cookie.name, cookie.value)], requestSession: session);
            toast('success'.tr);
            setStateSafely(() {
              _refreshIgneousState = LoadingState.success;
            });
            return;
          }
        }
      }

      snack('refreshIgneousFailed'.tr, 'Sad panda');
      setStateSafely(() {
        _refreshIgneousState = LoadingState.error;
      });
      return;
    } on DioException catch (e) {
      log.error('Refresh igneous failed', e.type);
      snack('refreshIgneousFailed'.tr, e.errorMsg ?? '');
      setStateSafely(() {
        _refreshIgneousState = LoadingState.error;
      });
      return;
    } on EHSiteException catch (e) {
      log.error('Refresh igneous failed', e.type);
      snack('refreshIgneousFailed'.tr, e.message);
      setStateSafely(() {
        _refreshIgneousState = LoadingState.error;
      });
      return;
    } catch (e) {
      log.error('Refresh igneous failed', e.runtimeType);
      snack('refreshIgneousFailed'.tr, e.toString());
      setStateSafely(() {
        _refreshIgneousState = LoadingState.error;
      });
      return;
    }
  }

  Future<void> _initDio() async {
    if (_dio != null) {
      return;
    }

    _dio = Dio(BaseOptions(
      connectTimeout: Duration(milliseconds: networkSetting.connectTimeout.value),
      receiveTimeout: Duration(milliseconds: networkSetting.receiveTimeout.value),
    ));

    _dio!.httpClientAdapter = ExEchAdapter();
    _dio!.interceptors.add(EHTimeoutTranslator());
  }
}
