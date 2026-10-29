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

/// 设备端日志目录（filesDir/logs，无需权限）；没有原生通道（测试环境）返回 null。
Future<String?> getLogDir() async {
  try {
    final dir = await _channel.invokeMethod<String>('appLogDir');
    return (dir == null || dir.isEmpty) ? null : dir;
  } on MissingPluginException {
    return null;
  }
}

/// 覆盖模式：把内容直接写回「打开 ROM」时选中的那个文件。
///
/// 不经过系统「另存为」，因此不会产生 patched 副本。
/// 返回写入成功的 Uri；没有可覆盖的源文件时抛异常。
Future<String?> overwriteSourceRom(Uint8List bytes) async {
  return _channel.invokeMethod<String>('overwrite', {'bytes': bytes});
}

/// 当前是否已记录可覆盖的源文件（即本次会话用「打开 ROM」选过文件）。
Future<bool> hasOverwriteSource() async {
  try {
    final name = await _channel.invokeMethod<String>('sourceName');
    return name != null && name.isNotEmpty;
  } on MissingPluginException {
    return false;
  }
}

/// 读取设置文件内容；没有原生通道时返回 null。
Future<String?> readSettingsFile() async {
  try {
    return await _channel.invokeMethod<String>('readSettings');
  } on MissingPluginException {
    return null;
  }
}

/// 写入设置文件内容。
Future<void> writeSettingsFile(String text) async {
  try {
    await _channel.invokeMethod<String>('writeSettings', {'text': text});
  } on MissingPluginException {
    // 测试环境没有原生通道，忽略
  }
}

/// 用系统浏览器/应用打开外部链接；无原生通道（测试环境）或打开失败返回 false。
Future<bool> openUrl(String url) async {
  if (url.isEmpty) return false;
  try {
    final ok = await _channel.invokeMethod<bool>('openUrl', {'url': url});
    return ok ?? false;
  } on MissingPluginException {
    return false;
  }
}
