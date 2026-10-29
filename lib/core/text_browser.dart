import 'dart:typed_data';

import 'fe_rom.dart';
import 'text_codec.dart';

/// 文本浏览：枚举 ROM 内全部文本条目并渲染为可读字符串。
class TextBrowser {
  final FeRom rom;
  TextBrowser(this.rom);

  int get maxId {
    // 文本指针表末尾会有无效/空指针，但偶尔中间也有；容忍连续 32 个无效才算结束
    var n = 0;
    var miss = 0;
    for (var id = 0; id < 0x7FFF && miss < 32; id++) {
      final a = rom.textEntryOffset(id);
      if (a < 0) {
        miss++;
        continue;
      }
      miss = 0;
      n = id + 1;
    }
    return n;
  }

  /// 渲染一条文本（含控制码的可读形式）。
  String render(int id) {
    // 明文 UTF-8：文本已经是可读字符，直接解码字节流。
    // 不能走下面的双字节查表——UTF-8 汉字是 3 字节，按双字节拆会出乱码。
    if (rom.textEncoding == FeTextEncoding.plainUtf8) {
      return Utf8Codec.decode(rom.decodeTextBytesAt(id));
    }
    final raw = rom.decodeTextBytesAt(id);
    return _format(raw);
  }

  String _format(Uint8List raw) {
    final sb = StringBuffer();
    var i = 0;
    while (i < raw.length) {
      final b = raw[i];
      if (b == 0x00) break;
      if (b < 0x20) {
        // FEditorAdv 控制码：0xXX [参数...]
        sb.write(_ctrl(raw, i, (n) => i = n));
        continue;
      }
      if (b < 0x80) {
        sb.writeCharCode(b);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) break;
      final code = (b << 8) | raw[i + 1];
      final ch = rom.lookupChar(code);
      sb.write(
          ch ?? '[${code.toRadixString(16).padLeft(4, '0').toUpperCase()}]');
      i += 2;
    }
    return sb.toString();
  }

  /// 控制码的可读形式。常见：
  /// 0x01=行等待 0x02=清屏等待 0x03=段尾换行 0x09=换行
  /// 0x0B/0x0C=清屏 0x0F=变色(1参) 0x10=变量(1参) 0x1A=菜单项
  String _ctrl(Uint8List raw, int i, void Function(int) advance) {
    final b = raw[i];
    String name;
    var args = 0;
    switch (b) {
      case 0x01:
        name = '⏳';
        break;
      case 0x02:
        name = '▼';
        break;
      case 0x03:
        name = '¶';
        break;
      case 0x05:
        name = '❚';
        args = 1;
        break;
      case 0x09:
        name = '\\n';
        break;
      case 0x0B:
        name = '⌂';
        break;
      case 0x0C:
        name = '⌂';
        break;
      case 0x0F:
        name = '🎨';
        args = 1;
        break;
      case 0x10:
        name = '＃';
        args = 2;
        break;
      case 0x1A:
        name = '▸';
        args = 1;
        break;
      default:
        name = '[${b.toRadixString(16).padLeft(2, '0')}]';
    }
    i++;
    var argText = '';
    for (var k = 0; k < args && i + 1 < raw.length; k++) {
      final v = raw[i] | (raw[i + 1] << 8);
      argText += v.toRadixString(16).padLeft(4, '0').toUpperCase();
      i += 2;
    }
    advance(i);
    return argText.isEmpty ? name : '$name$argText';
  }
}
