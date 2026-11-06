import 'package:flutter/material.dart';

import '../core/app_meta.dart';
import '../core/file_picker_service.dart';
import 'log_page.dart';

/// 「关于」页：应用信息、更新日志、关于本工具、开源致谢、免责声明、快捷入口。
///
/// 不依赖 ROM，未打开 ROM 时也能进入。
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _appInfoCard(context, scheme),
          const SizedBox(height: 12),
          _repoCard(context),
          const SizedBox(height: 8),
          _feedbackCard(context),
          const SizedBox(height: 16),
          _sectionHeader(context, '支持本项目'),
          _sponsorCard(context),
          const SizedBox(height: 16),
          _sectionHeader(context, '关于本工具'),
          _introCard(context),
          const SizedBox(height: 16),
          _sectionHeader(context, '开源致谢与参考'),
          _creditsCard(context),
          const SizedBox(height: 16),
          _sectionHeader(context, '免责声明'),
          _disclaimerCard(context),
          const SizedBox(height: 16),
          _sectionHeader(context, '快捷入口'),
          _entryTile(
            context,
            icon: Icons.notes,
            title: '应用日志',
            subtitle: '错误与操作记录，可复制排查',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LogViewerPage()),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }

  Widget _appInfoCard(BuildContext context, ColorScheme scheme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.shield, size: 30, color: scheme.primary),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(appName,
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text('v$appVersion · $packageName',
                      style:
                          TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 开源仓库入口：点击跳转 GitHub，可在手机上查看源码与提 issue。
  Widget _repoCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: () => _openLink(context, repoUrl),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: Icon(Icons.code, color: scheme.primary),
          title: const Text('开源仓库',
              style: TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('$repoName · GPL-3.0，点击查看源码'),
          trailing: const Icon(Icons.open_in_new, size: 20),
        ),
      ),
    );
  }

  /// 反馈入口：点击跳转加入腾讯频道【纹章修改器】。
  Widget _feedbackCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: InkWell(
        onTap: () => _openFeedback(context),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: Icon(Icons.forum_outlined, color: scheme.primary),
          title: Text(
            '加入腾讯频道【$feedbackChannel】',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          subtitle: const Text('意见反馈 / 使用交流，点击跳转'),
          trailing: const Icon(Icons.open_in_new, size: 20),
        ),
      ),
    );
  }

  Future<void> _openFeedback(BuildContext context) =>
      _openLink(context, feedbackUrl);

  /// 赞助卡片：写明免费开源、为何需要赞助、跳转外部浏览器、完全自愿。
  Widget _sponsorCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.favorite_outline, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                const Text(
                  '如果觉得有帮助，欢迎小额赞助',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const _Para(
              '本工具完全免费开源，无广告，所有功能无需付费解锁。',
            ),
            const SizedBox(height: 8),
            const _Para(
              '后续版本主要由 AI 协助维护迭代，会产生模型与算力相关开销。'
              '如果您觉得工具对您有帮助，欢迎小额赞助以平衡维护成本。',
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => _confirmSponsor(context),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('前往爱发电'),
            ),
            const SizedBox(height: 8),
            Text(
              '⚠️ 点击将跳转外部浏览器（爱发电），赞助完全自愿，不影响任何功能使用。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 跳外部浏览器前先确认一次——用户在应用里点的按钮，
  /// 突然把应用切到浏览器容易让人以为是误触。
  Future<void> _confirmSponsor(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('将跳转到外部浏览器'),
        content: const Text(
          '即将打开爱发电页面（需要联网）。\n\n'
          '赞助完全自愿，不影响任何功能的使用——不赞助也能用全部功能。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _openLink(context, sponsorUrl);
  }

  Future<void> _openLink(BuildContext context, String url) async {
    final ok = await openUrl(url);
    if (!context.mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('无法打开链接，请手动访问：$url')),
      );
    }
  }

  Widget _introCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            _Para(
              '长期以来，GBA 火焰纹章的修改调试大多只能在电脑端完成。'
              '主流工具 FEBuilderGBA 基于 .NET/WinForms 开发，体量庞大，无法在移动端运行。',
            ),
            SizedBox(height: 10),
            _Para(
              '为填补安卓端的使用空白，本工具使用 Dart 从零独立开发：'
              '没有直接复用原有源码，重新实现了 ROM 解析、读取与写入引擎，'
              '让你可以在手机上便捷完成基础数据调整、素材预览等操作。',
            ),
          ],
        ),
      ),
    );
  }

  Widget _creditsCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            _CreditTitle('FEBuilderGBA（GPL-3.0，7743 著）'),
            SizedBox(height: 4),
            _Para(
              '本项目的灵感来源与致敬对象。开发时参考了该项目整理的地址表、'
              '数据结构与字段布局；受平台限制，无法复用其代码，'
              '全部核心逻辑由 Dart 独立重写。',
            ),
            SizedBox(height: 12),
            _CreditTitle(
                'FireEmblemUniverse 反编译工程（fireemblem8u、fe7_us、fireemblem6j 等）'),
            SizedBox(height: 4),
            _Para(
              '感谢社区反编译成果，为本工具核对角色、职业、战斗动画、'
              '地图单位等结构体定义提供了关键参考。',
            ),
            SizedBox(height: 12),
            Divider(height: 1),
            SizedBox(height: 10),
            _Para(
              '本工具衍生自 GPL-3.0 作品，遵循 GPL-3.0：开源并保留上述署名。',
              small: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _disclaimerCard(BuildContext context) {
    const items = [
      '本工具不内置、不提供任何受版权保护的游戏 ROM 和素材资源。',
      '本工具申请网络权限**仅**用于 MCP 调试功能的本机回环 / 局域网连接，'
          '不向任何外部服务器发送你的 ROM、游戏数据或个人信息。'
          'MCP 默认关闭，且默认只允许本机访问。',
      '请仅使用你合法持有、由自有实体卡带导出的 ROM 文件进行修改。',
      'ROM 修改写入操作存在不可逆风险。修改前请务必备份原始文件；'
          '因未备份造成的数据丢失，开发者不承担责任。',
      '工具永久免费，无广告、无内购。',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 18,
                      child: Text('${i + 1}.',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                    ),
                    Expanded(
                      child: Text(items[i],
                          style: const TextStyle(fontSize: 13, height: 1.45)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _entryTile(BuildContext context,
      {required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap}) {
    return Card(
      child: ListTile(
        leading: Icon(icon, size: 24),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, size: 20),
        onTap: onTap,
      ),
    );
  }
}

class _Para extends StatelessWidget {
  final String text;
  final bool small;
  const _Para(this.text, {this.small = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: small ? 12 : 13,
        height: 1.55,
        color: small ? Colors.grey.shade700 : null,
      ),
    );
  }
}

class _CreditTitle extends StatelessWidget {
  final String text;
  const _CreditTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text,
        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold));
  }
}
