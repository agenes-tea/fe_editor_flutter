import 'package:flutter/foundation.dart';

import 'rom_session.dart';

/// 已打开 ROM 的集合（工作区）。
///
/// 与界面无关：这里只管「打开了哪些 ROM、当前操作哪一个、增删切换」，
/// 主页监听它并重绘。跨版本移植要源/目标两个 ROM 同时驻留，
/// 所以这里保存的是列表而不是单个会话——每个会话的数据数组、
/// 编辑记录、表布局彼此独立。
class RomWorkspace extends ChangeNotifier {
  final List<RomSession> _sessions = [];
  int? _activeId;

  /// 已打开的会话（按打开顺序）。
  List<RomSession> get sessions => List.unmodifiable(_sessions);

  /// 当前操作的会话；没有打开任何 ROM 时为 null。
  RomSession? get active {
    for (final s in _sessions) {
      if (s.id == _activeId) return s;
    }
    return null;
  }

  bool get isEmpty => _sessions.isEmpty;

  /// 打开一个 ROM 并切过去。
  ///
  /// 同一份 ROM（内容指纹相同）重复打开时只切换，不重复占用内存。
  /// 无法识别时返回 null，且不改动已有会话。
  Future<RomSession?> open(Uint8List data, String fileName) async {
    final session = RomSession.open(data, fileName);
    if (session == null) return null;

    for (final existing in _sessions) {
      if (existing.sameRomAs(session)) {
        _activeId = existing.id;
        notifyListeners();
        return existing;
      }
    }

    await session.attachZhTableIfNeeded();
    _sessions.add(session);
    _activeId = session.id;
    notifyListeners();
    return session;
  }

  void activate(RomSession session) {
    if (_activeId == session.id) return;
    if (!_sessions.contains(session)) return;
    _activeId = session.id;
    notifyListeners();
  }

  /// 关闭一个会话；关的是当前会话时自动切到剩下的最后一个。
  void close(RomSession session) {
    if (!_sessions.remove(session)) return;
    if (_activeId == session.id) {
      _activeId = _sessions.isEmpty ? null : _sessions.last.id;
    }
    notifyListeners();
  }

  /// 关闭全部会话。
  void closeAll() {
    if (_sessions.isEmpty) return;
    _sessions.clear();
    _activeId = null;
    notifyListeners();
  }
}
