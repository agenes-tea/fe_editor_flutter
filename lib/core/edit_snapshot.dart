import 'dart:typed_data';

import 'editable_rom.dart';

/// 一次事务快照：某个时刻的完整字节与编辑记录长度。
///
/// 与 [EditableRom.revertAll] 的区别是**回到任意时刻**而不是回到刚打开时：
/// 它是 MCP 层「先试一下不行就回滚」与 dry run 预演的实现基础。
///
/// [data] 是整份 ROM 的副本（16~32MB），所以 [SnapshotStore] 限量保存，
/// 超出时丢最早的——不限制会在手机上吃光内存。
class EditSnapshot {
  final String id;
  final String label;

  /// 快照时已经改过的字节数（给用户看的「改到哪一步」）。
  final int changedBytes;

  /// 快照时的编辑记录条数，回滚时据此截断 `edits`。
  final int editsLength;

  final Uint8List data;

  EditSnapshot._(
    this.id,
    this.label,
    this.changedBytes,
    this.editsLength,
    this.data,
  );
}

/// 单个 ROM 会话的快照栈（先进先出，超出上限丢最早的）。
class SnapshotStore {
  final int maxEntries;
  final List<EditSnapshot> _items = [];
  int _next = 1;

  SnapshotStore({this.maxEntries = 8});

  List<EditSnapshot> get all => List.unmodifiable(_items);

  EditSnapshot? byId(String id) {
    for (final s in _items) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 最近一个快照（没有则 null）。
  EditSnapshot? get latest => _items.isEmpty ? null : _items.last;

  /// 记录当前状态。
  EditSnapshot take(EditableRom rom, {String label = ''}) {
    final snap = EditSnapshot._(
      's${_next++}',
      label,
      rom.changedByteCount,
      rom.edits.length,
      Uint8List.fromList(rom.buffer.data),
    );
    _items.add(snap);
    while (_items.length > maxEntries) {
      _items.removeAt(0);
    }
    return snap;
  }

  /// 恢复到 [snap] 的状态。快照列表本身不变（快照是不可变数据）。
  bool restore(EditableRom rom, EditSnapshot snap) {
    if (snap.data.length != rom.buffer.length) return false;
    rom.buffer.data.setAll(0, snap.data);
    if (rom.edits.length > snap.editsLength) {
      rom.edits.removeRange(snap.editsLength, rom.edits.length);
    } else if (rom.edits.length < snap.editsLength) {
      // 不该发生（edits 只追加）；出现说明状态被意外清空，只能整体丢弃
      rom.edits.clear();
    }
    // 图像缓存靠内容版本号判定过期，直接改字节不会自动触发。
    rom.touchContent();
    return true;
  }

  /// 丢掉一个快照（预演用的临时快照不该留在栈里）。
  void drop(String id) => _items.removeWhere((s) => s.id == id);

  void clear() => _items.clear();
}

/// 两段字节之间的差异。
class ByteDiff {
  final int offset;
  final int before;
  final int after;

  const ByteDiff(this.offset, this.before, this.after);
}

/// 对比 [old] 与 [current]，返回改动字节（最多 [limit] 条）与总数。
({List<ByteDiff> diffs, int total, List<({int offset, int length})> regions})
    diffBytes(Uint8List old, Uint8List current, {int limit = 300}) {
  final diffs = <ByteDiff>[];
  final regions = <({int offset, int length})>[];
  var total = 0;
  final n = old.length < current.length ? old.length : current.length;
  int? runStart;
  int runEnd = 0;

  void flush() {
    final start = runStart;
    if (start == null) return;
    regions.add((offset: start, length: runEnd - start));
    runStart = null;
  }

  for (var i = 0; i < n; i++) {
    if (old[i] == current[i]) {
      flush();
      continue;
    }
    total++;
    if (diffs.length < limit) {
      diffs.add(ByteDiff(i, old[i], current[i]));
    }
    runStart ??= i;
    runEnd = i + 1;
  }
  flush();
  return (diffs: diffs, total: total, regions: regions);
}
