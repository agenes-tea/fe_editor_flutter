import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'custom_roster.dart';
import 'file_picker_service.dart';

/// 轻量设置存储。
///
/// 项目约定不引入第三方插件，所以直接用原生 filesDir 里的小文本文件
/// （`filesDir/settings`，一行一个 `key=value`），通过已有的
/// `fe_editor/files` 通道读写。
class AppSettings {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  /// 覆盖模式：保存时直接写回原 ROM 文件，不生成 `_modified` 副本。
  bool overwriteMode = false;

  /// 主题模式索引：0=跟随系统，1=浅色，2=暗色。
  int themeModeIndex = 0;

  /// 主题变化通知。`FeEditorApp` 监听它重建 MaterialApp。
  final ValueNotifier<int> themeNotifier = ValueNotifier(0);

  /// 自定义角色名单，按 ROM 指纹隔离（`romFingerprint -> CustomRoster`）。
  ///
  /// 用指纹当 key 的原因：玩家的名单只对那份 ROM 有意义
  /// （改版的 52 号角色和原版的 52 号完全不是一个东西），
  /// 换个 ROM 就该是另一份名单，不能串。
  final Map<int, CustomRoster> _rosters = {};

  CustomRoster rosterFor(int romFingerprint) =>
      _rosters[romFingerprint] ?? CustomRoster.empty;

  Future<void> setRoster(int romFingerprint, CustomRoster roster) async {
    if (roster.isEmpty) {
      _rosters.remove(romFingerprint);
    } else {
      _rosters[romFingerprint] = roster;
    }
    await _save();
  }

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final text = await readSettingsFile();
    if (text != null) {
      for (final line in text.split('\n')) {
        final i = line.indexOf('=');
        if (i <= 0) continue;
        final k = line.substring(0, i).trim();
        final v = line.substring(i + 1).trim();
        if (k == 'overwriteMode') overwriteMode = v == '1';
        if (k == 'themeMode') {
          final n = int.tryParse(v);
          if (n != null && n >= 0 && n <= 2) themeModeIndex = n;
        }
        // roster_<指纹>=<JSON>：只做语法层解析，越界检查在使用时按当次 ROM 做
        if (k.startsWith('roster_')) {
          final fpr = int.tryParse(k.substring('roster_'.length));
          if (fpr == null) continue;
          final r = CustomRoster.fromJson(_tryDecode(v), unitCount: 1 << 20);
          if (!r.isEmpty) _rosters[fpr] = r;
        }
      }
    }
    themeNotifier.value = themeModeIndex;
  }

  Future<void> setOverwriteMode(bool value) async {
    overwriteMode = value;
    await _save();
  }

  Future<void> setThemeMode(int index) async {
    if (index == themeModeIndex) return;
    themeModeIndex = index;
    themeNotifier.value = index;
    await _save();
  }

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _save() async {
    final buf = StringBuffer()
      ..write('overwriteMode=${overwriteMode ? 1 : 0}\n')
      ..write('themeMode=$themeModeIndex\n');
    for (final e in _rosters.entries) {
      buf.write('roster_${e.key}=${e.value.toJsonString()}\n');
    }
    await writeSettingsFile(buf.toString());
  }
}
