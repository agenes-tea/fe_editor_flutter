import 'dart:typed_data';

import 'edit_snapshot.dart';
import 'editable_rom.dart';
import 'fe_rom.dart';
import 'rom_info.dart';
import 'text_codec.dart';
import 'text_writer.dart';
import 'zh_table.dart';
import 'zh_tables_data.dart';

/// 一个已打开 ROM 的会话。
///
/// 每次打开 ROM 都是独立的 [EditableRom]（独立数据数组、独立编辑记录），
/// 所以多个作品可以同时驻留内存、互不干扰；[id] 在同一进程内唯一，
/// 供界面按会话区分（切换当前编辑目标、区分图像缓存）。
class RomSession {
  static int _nextId = 1;

  /// 会话唯一标识（进程内自增，不复用）。
  final int id;

  final String fileName;
  final EditableRom rom;

  /// 打开时的表布局（即 [rom] 快照识别出的版本）。
  final RomTable table;

  /// 事务快照栈：MCP 的 snapshot / rollback 与 dry run 预演都靠它。
  final SnapshotStore snapshots = SnapshotStore();

  /// 名字/文本显示应读实时数据：改动后仍要读到新值。
  FeRom get liveRom => rom.liveRom;

  RomSession._(this.id, this.fileName, this.rom, this.table);

  /// 识别失败时返回 null（调用方负责给出提示）。
  static RomSession? open(Uint8List data, String fileName) {
    final table = FeRom.detectTable(data);
    if (table == null) return null;
    final edit = EditableRom.open(data, table);
    return RomSession._(_nextId++, fileName, edit, table);
  }

  /// 作品代号：FE6 / FE7J / FE7U / FE8J / FE8U。
  String get versionId => table.id;

  String get versionName => table.name;

  /// 作品代数（6 / 7 / 8）。三作的表地址不同，移植时需要它分支。
  int get generation => int.parse(versionId[2]);

  /// 该作品是否为 FE8 系（战斗动画、遭遇槽等能力集中在 FE8）。
  bool get isFe8 => generation == 8;

  /// 同代不同区（日版 / 美版）。
  bool sameGenerationAs(RomSession other) =>
      generation == other.generation;

  /// 内容指纹（区分同一作品的日版/汉化/改版）。
  int get fingerprint => rom.rom.fingerprint;

  /// 两份会话是否同一份 ROM。
  bool sameRomAs(RomSession other) => fingerprint == other.fingerprint;

  /// 未识别引擎要试内嵌码表才能读出汉化文本。
  bool get needsZhTable => liveRom.textEncoding == FeTextEncoding.unknown;

  /// 挂载中文码表（汉化版 Huffman 文本用）。
  ///
  /// 先试内嵌码表，再试 assets；匹配率不足 0.5 就摘掉，保持「引擎未识别」。
  Future<void> attachZhTableIfNeeded() async {
    final r = liveRom;
    if (r.zhTable != null) return;
    final embedded = switch (versionId) {
      'FE6' => zhTblFE6,
      'FE7J' || 'FE7U' => zhTblFE7,
      'FE8J' || 'FE8U' => zhTblFE8,
      _ => null,
    };
    if (embedded != null) {
      // 走 attachZhTable：它同时作用到快照与实时视图，
      // 只写 liveRom 会让 TextWriter 读到的 rom.zhTable 仍是空
      rom.attachZhTable(ZhTable(embedded));
      if (r.zhTableMatchRatio() >= 0.5) return;
      rom.attachZhTable(null);
    }
    try {
      final tbl = await ZhTable.loadFromAssets('assets/tbl/$versionId.tbl');
      if (tbl == null) return;
      rom.attachZhTable(tbl);
      if (r.zhTableMatchRatio() >= 0.5) return;
      rom.attachZhTable(null);
    } catch (_) {
      // 没有可用的码表：保持未识别引擎，其它功能不受影响
    }
  }

  /// 文本可写性（按实时数据判定：改名或挂码表后依旧成立）。
  bool get textWritable => TextWriter(rom).supported;

  /// 该 ROM 当前是否挂上了中文码表（汉化版 Huffman 解码/编码依赖它）。
  bool get hasZhTable => liveRom.zhTable != null;
}
