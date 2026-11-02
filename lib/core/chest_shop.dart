import 'editable_rom.dart';
import 'fe_rom.dart';
import 'chapter_events.dart';

/// 章节事件里 CHES（宝箱）/ SHOP（商店）条目的**第 2 字**语义与原地写回。
///
/// 三种版本全部实测（五版本探针 `_probe_shop_test.dart`）：
/// - **CHES（check 低 16 位 == 7）**：第 2 字低 16 位 = 奖励道具 ID，
///   高 16 位 = 附加字段（原版三作全为 0；个别改版会用它存耐久/数量，
///   例如 0xBB8/0x7D0）——写入时**高 16 位原样保留**，只改低 16 位。
/// - **SHOP（check 低 16 位 == 10）**：第 2 字 = GBA 指针，指向
///   **u16 道具 ID 数组（0 结尾）**。数组在 ROM 里是**密集排布**的
///   （一个紧挨一个），所以**只能原地替换已有槽位**，不能扩容
///   （扩容会顶进下一张列表，改坏别的商店）。
///
/// 反编译佐证：fireemblem8u `src/events_shoplist.c` 的
/// `ShopList_Event_Ch2Armory[]`（u16，ITEM_NONE 结尾）与 FE8U 原版
/// `0x89ED7CC` 起的数据逐字一致；`EvtListCHES(item, x, y)` 宏
/// （`include/eventscript.h`）第 2 参数就是道具 ID。
class ChestShop {
  final EditableRom edit;

  /// 读实时 buffer 的 FeRom（商店列表被改过后要读得到新值）。
  FeRom get rom => edit.liveRom;

  ChestShop(this.edit);

  bool isChest(ChapterEvent e) => (e.check & 0xFFFF) == 7;
  bool isShop(ChapterEvent e) => (e.check & 0xFFFF) == 10;

  /// 宝箱当前奖励道具 ID（第 2 字低 16 位）。
  int chestItemOf(ChapterEvent e) => e.script & 0xFFFF;

  /// 从**实时 buffer** 重读宝箱奖励（[chestItemOf] 读的是事件缓存里
  /// 按原快照生成的值，写回后要读新值用这个）。
  int chestItemNow(ChapterEvent e) {
    final at = e.addr + 4;
    if (!edit.buffer.inRange(at, 4)) return chestItemOf(e);
    return edit.buffer.u32(at) & 0xFFFF;
  }

  /// 宝箱第 2 字高 16 位（附加字段；原版为 0）。
  int chestExtraOf(ChapterEvent e) => (e.script >> 16) & 0xFFFF;

  /// 商店列出的道具 ID（u16 数组，0 结尾；指针无效返回空）。
  List<int> shopItemsOf(ChapterEvent e) {
    final ptr = e.script;
    if (!FeRom.isPointer(ptr, rom.data.length)) return const [];
    final base = FeRom.toOffset(ptr);
    final out = <int>[];
    for (var i = 0; i < 100; i++) {
      final at = base + i * 2;
      if (at + 2 > rom.data.length) break;
      final v = FeRom.u16(rom.data, at);
      if (v == 0) break;
      out.add(v);
    }
    return out;
  }

  /// 改宝箱奖励道具：只写第 2 字低 16 位，高 16 位原样保留。
  ///
  /// 返回实际改动的字节数（0 = 内容相同未写）。越界返回 -1。
  int setChestItem(ChapterEvent e, int itemId) {
    final at = e.addr + 4;
    if (itemId < 0 || itemId > 0xFFFF) return -1;
    if (!edit.buffer.inRange(at, 4)) return -1;
    final cur = edit.buffer.u32(at);
    final low = cur & 0xFFFF;
    if (low == itemId) return 0;
    edit.buffer.writeU16(at, itemId);
    edit.edits.add(ByteEdit(at, low, itemId));
    return 2;
  }

  /// 改商店第 [slot] 个槽位的道具 ID（**只替换、不扩容**）。
  ///
  /// [slot] 必须落在当前列表长度内（0 结尾标记之前）；
  /// 返回实际改动字节数（0 = 内容相同未写），-1 = 越界/槽位不存在。
  int setShopItem(ChapterEvent e, int slot, int itemId) {
    final items = shopItemsOf(e);
    if (slot < 0 || slot >= items.length) return -1;
    if (itemId < 0 || itemId > 0xFFFF) return -1;
    final base = FeRom.toOffset(e.script);
    final at = base + slot * 2;
    if (!edit.buffer.inRange(at, 2)) return -1;
    final cur = edit.buffer.u16(at);
    if (cur == itemId) return 0;
    edit.buffer.writeU16(at, itemId);
    edit.edits.add(ByteEdit(at, cur, itemId));
    return 2;
  }
}
