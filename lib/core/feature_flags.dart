/// 功能开关。
class Features {
  Features._();

  /// 章节（地图 + 初始单位，已合并成一个页面）。
  static const bool chapter = true;

  /// 游戏内调试器。
  ///
  /// 现状见 AGENTS.md 第 20c 节：补丁会把跳板目标与 payload 写在同一个地址区间，
  /// 装完后游戏无法启动。在拿到可验证的构建前不对外暴露入口。
  static const bool gameDebugger = false;
}
