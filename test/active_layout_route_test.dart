import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/pages/home_page.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/utils/route_util.dart';

void main() {
  testWidgets('settings opens in the active tablet column when desktop is saved', (tester) async {
    final previousSettings = styleSetting;
    styleSetting = StyleSetting();
    addTearDown(() {
      styleSetting = previousSettings;
      Get.reset();
    });
    styleSetting.layout.value = LayoutMode.desktop;
    styleSetting.layoutFollowOrientation.value = true;
    styleSetting.portraitLayout.value = LayoutMode.tabletV2;
    styleSetting.actualLayout = LayoutMode.tabletV2;

    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Navigator(
              key: Get.nestedKey(leftV2),
              onGenerateRoute: (settings) => GetPageRoute(
                settings: settings,
                page: () => Text(settings.name ?? ''),
                transition: Transition.noTransition,
              ),
            ),
          ),
        ),
      ),
    );

    unawaited(toRoute<void>(Routes.setting));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(Get.nestedKey(leftV2)!),
        matching: find.text(Routes.setting),
      ),
      findsOneWidget,
    );
  });
}
