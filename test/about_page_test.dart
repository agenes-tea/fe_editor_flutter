import 'package:fe_editor/core/app_meta.dart';
import 'package:fe_editor/core/changelog.dart';
import 'package:fe_editor/ui/about_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('changelog 维护当前版本且在首条', () {
    expect(changelog.first.version, appVersion,
        reason: 'changelog 首条应是当前版本');
  });

  testWidgets('关于页：信息/反馈/致谢/免责/快捷入口齐全', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text(appName), findsOneWidget);
    expect(find.text('v$appVersion · $packageName'), findsOneWidget);
    // 反馈入口存在，更新日志已移除
    expect(find.textContaining('加入腾讯频道'), findsOneWidget);
    expect(find.text('更新日志'), findsNothing);
    expect(find.text('当前'), findsNothing, reason: '更新日志区块已移除');

    // 滚动到底，让下方区块构建出来（ListView 懒加载）
    final listView = find.byType(ListView);
    Future<void> scrollTo(String text) async {
      await tester.scrollUntilVisible(find.text(text), 300,
          scrollable: find.descendant(
              of: listView, matching: find.byType(Scrollable)));
      await tester.pump(const Duration(milliseconds: 40));
    }

    await scrollTo('关于本工具');
    expect(find.textContaining('Dart 从零独立开发'), findsWidgets);
    await scrollTo('开源致谢与参考');
    expect(find.textContaining('FEBuilderGBA'), findsWidgets);
    await scrollTo('免责声明');
    expect(find.textContaining('不内置、不提供'), findsWidgets);
    await scrollTo('应用日志');

    for (var i = 0; i < 6; i++) {
      await tester.drag(listView, const Offset(0, -400));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(find.textContaining('永久免费'), findsWidgets);
    expect(find.textContaining('GPL-3.0'), findsWidgets);
    expect(find.textContaining('fireemblem8u'), findsWidgets);
    expect(find.text('补丁库'), findsNothing);
  });
}
