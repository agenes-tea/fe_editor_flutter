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
    // 开源仓库入口：仓库地址在 app_meta 里统一维护
    expect(find.text('开源仓库'), findsOneWidget);
    expect(find.textContaining(repoName), findsWidgets);
    expect(repoUrl, 'https://github.com/agenes-tea/fe_editor_flutter');
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

  testWidgets('关于页：支持本项目卡片（免费开源 + 自愿赞助 + 外部跳转提示）',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('支持本项目'), findsOneWidget);
    expect(find.textContaining('完全免费开源'), findsWidgets);
    expect(find.textContaining('无需付费解锁'), findsWidgets);
    expect(find.textContaining('AI 协助维护'), findsWidgets);
    expect(find.textContaining('小额赞助'), findsWidgets);
    // 必须明写「跳外部浏览器」与「不影响功能」——这是给用户的知情提示
    expect(find.textContaining('跳转外部浏览器'), findsWidgets);
    expect(find.textContaining('赞助完全自愿'), findsWidgets);
    expect(find.textContaining('不影响任何功能使用'), findsWidgets);
    expect(find.text('前往爱发电'), findsOneWidget);
    // 链接统一在 app_meta 里维护
    expect(sponsorUrl, 'https://afdian.com/a/Polite');
  });

  testWidgets('关于页：点「前往爱发电」先弹确认，不直接跳走', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pump(const Duration(milliseconds: 200));

    await tester.tap(find.text('前往爱发电'));
    await tester.pumpAndSettle();

    // 确认框出现，且把「自愿/不影响功能」再说一遍
    expect(find.text('将跳转到外部浏览器'), findsOneWidget);
    expect(find.textContaining('不影响任何功能的使用'), findsWidgets);

    // 取消后对话框关闭，不残留
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('将跳转到外部浏览器'), findsNothing);
  });
}
