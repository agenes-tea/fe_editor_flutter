import 'dart:typed_data';

import 'package:flutter/services.dart';

const _channel = MethodChannel('fe_editor/files');

/// 调用系统文件选择器，返回 ROM 缓存文件路径；用户取消时返回 null。
Future<String?> pickRomFile() async {
  final path = await _channel.invokeMethod<String>('pickRom');
  return (path == null || path.isEmpty) ? null : path;
}

/// 用系统文件选择器选一个配方 JSON 文件，直接返回文本内容（不经过缓存文件；
/// 取消或测试环境无原生通道时返回 null）。
Future<String?> pickRecipeFile() async {
  try {
    final text = await _channel.invokeMethod<String>('pickJson');
    return (text == null || text.isEmpty) ? null : text;
  } on MissingPluginException {
    return null;
  }
}

/// 选一个文本文件（对话补丁等），读回 UTF-8 内容；取消或无原生通道时返回 null。
Future<String?> pickTextFile() async {
  try {
    final text = await _channel.invokeMethod<String>('pickText');
    return (text == null || text.isEmpty) ? null : text;
  } on MissingPluginException {
    return null;
  }
}

/// 选一个补丁文件（.ips/.ups），读进缓存后返回真实路径；取消时返回 null。
Future<String?> pickPatchFile() async {
  final path = await _channel.invokeMethod<String>('pickPatch');
  return (path == null || path.isEmpty) ? null : path;
}

/// 选一张图片（肖像导入用），读进缓存后返回真实路径；取消时返回 null。
Future<String?> pickImageFile() async {
  final path = await _channel.invokeMethod<String>('pickImage');
  return (path == null || path.isEmpty) ? null : path;
}

/// 把改后的 ROM 分享到系统，让用户挑模拟器（mGBA 等）直接打开。
///
/// 成功返回 null；失败/无原生通道时返回原因文本（给界面提示用）。
Future<String?> shareGbaRom(String name, Uint8List bytes) async {
  try {
    await _channel.invokeMethod('shareGbaRom', {
      'name': name,
      'bytes': bytes,
    });
    return null;
  } on PlatformException catch (e) {
    return e.code == 'NO_TARGET'
        ? '没找到能接收 ROM 的应用（请先安装 mGBA 等模拟器）'
        : (e.message ?? '分享失败');
  } on MissingPluginException {
    return '当前环境没有原生通道，无法分享';
  }
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
///
/// 原生分支 `result.success(true)` 回的是 **bool**，所以这里**不能**用
/// `invokeMethod<String>`（会把 bool cast 成 String? 抛 `type 'bool' is not a
/// subtype of type 'String?'`）。用无泛型调用，原生返回的 true 不作类型转换。
Future<void> writeSettingsFile(String text) async {
  try {
    await _channel.invokeMethod('writeSettings', {'text': text});
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
