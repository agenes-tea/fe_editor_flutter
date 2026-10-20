import 'package:flutter/services.dart';

const _channel = MethodChannel('fe_editor/files');

/// 调用系统文件选择器，返回 ROM 缓存文件路径；用户取消时返回 null。
Future<String?> pickRomFile() async {
  final path = await _channel.invokeMethod<String>('pickRom');
  return (path == null || path.isEmpty) ? null : path;
}

/// 用系统「另存为」保存文件，返回目标 Uri 字符串；取消时返回 null。
Future<String?> saveFile(String name, Uint8List bytes) async {
  return _channel.invokeMethod<String>('saveFile', {
    'name': name,
    'bytes': bytes,
  });
}
