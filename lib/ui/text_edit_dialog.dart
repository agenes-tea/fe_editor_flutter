import 'package:flutter/material.dart';

import '../core/editable_rom.dart';
import '../core/text_writer.dart';

/// 一次文本写入结果转成给用户看的提示语。
String textWriteMessage(TextWriteResult r) {
  switch (r.mode) {
    case TextWriteMode.identical:
      return '内容未变';
    case TextWriteMode.inPlace:
      return '已原地写入（等长）';
    case TextWriteMode.shorter:
      return '已原地写入（变短：${r.originalBytes} → ${r.newBytes} 字节）';
    case TextWriteMode.relocated:
      return '文本变长，已写入空位 0x${r.newOffset.toRadixString(16)} 并重指指针';
    case TextWriteMode.tooLong:
      return r.message.isEmpty ? '文本过长，写入失败' : r.message;
    case TextWriteMode.unsupportedEngine:
      return '该 ROM 文本引擎（Huffman / 未识别）暂不支持写入';
    case TextWriteMode.hasControlCodes:
      return '该条含控制码，暂不支持编辑';
    case TextWriteMode.charNotEncodable:
      return r.message.isEmpty ? '有字符无法编码' : r.message;
    case TextWriteMode.missing:
      return '找不到该条目';
  }
}

Future<void> _info(BuildContext context, String title, String msg) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(msg),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
      ],
    ),
  );
}

/// 弹出文本编辑对话框，写入成功（内容有变化）后返回 true。
///
/// 只对**明文引擎**（明文 UTF-8 / GBK）的**纯文本条目**生效；
/// Huffman / 未识别引擎、含控制码的对话条目会给说明并返回 false。
/// [header] 可放一段只读说明（例如「职业：领主」）。
///
/// 角色 / 职业 / 道具详情页与文本查看器共用此函数：传对应名字的文本 ID 即可。
Future<bool> showTextEditDialog(
  BuildContext context, {
  required EditableRom edit,
  required int textId,
  required String title,
  Widget? header,
}) async {
  final writer = TextWriter(edit);
  if (!writer.supported) {
    await _info(context, title,
        '该 ROM 的文本引擎未识别，暂不支持写入。');
    return false;
  }
  if (writer.entryBytes(textId) == null) {
    await _info(context, title, '这一项没有对应的文本条目（名字文本 ID = $textId）。');
    return false;
  }
  if (!writer.entryEditable(textId)) {
    await _info(context, title, '该条无法读取，暂不支持编辑。');
    return false;
  }

  final ctrl = TextEditingController(text: writer.currentText(textId) ?? '');
  final newText = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (header != null) ...[header, const SizedBox(height: 10)],
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 1,
              maxLines: 6,
              style: const TextStyle(fontSize: 14, height: 1.4),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text(
              '等长/变短原地写入；变长写空位并重指指针；Huffman 文本重定位写入。\n'
              '对话里的换行/按键/颜色等控制码以〔XX〕显示，保留它们即可（删掉即去掉该控制码）。',
              style: TextStyle(fontSize: 11, color: Theme.of(ctx).hintColor),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存')),
      ],
    ),
  );
  ctrl.dispose();
  if (newText == null) return false;

  final res = writer.write(textId, newText);
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(textWriteMessage(res))));
  }
  return res.ok && res.mode != TextWriteMode.identical;
}
