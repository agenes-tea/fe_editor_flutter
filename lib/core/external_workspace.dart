import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'app_log.dart';

const _channel = MethodChannel('fe_editor/files');

/// 外部工作区里的一个 ROM 文件。
class WorkspaceRom {
  /// 显示名（= 磁盘上的文件名，工作区里按它定位文件）。
  final String name;

  /// 字节数；未知为 -1。
  final int size;

  /// 最后修改时间（毫秒时间戳）；未知为 0。
  final int modified;

  const WorkspaceRom({
    required this.name,
    this.size = -1,
    this.modified = 0,
  });

  String get sizeLabel => size < 0 ? '大小未知' : '${(size / 1048576).toStringAsFixed(1)} MB';

  Map<String, Object?> toJson() => {
        'name': name,
        'size': size,
        'modified': modified,
        'size_mb': size < 0 ? null : double.parse((size / 1048576).toStringAsFixed(2)),
      };
}

/// 已授权的外部工作区目录。
class WorkspaceDir {
  final String uri;
  final String name;

  const WorkspaceDir({required this.uri, required this.name});

  static WorkspaceDir? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final uri = raw['uri'] as String?;
    final name = raw['name'] as String?;
    if (uri == null || uri.isEmpty) return null;
    return WorkspaceDir(uri: uri, name: name ?? '工作区');
  }
}

/// 外部工作区：用户选一个设备上的目录，App 每次启动自动读里面的 ROM。
///
/// 为什么需要它：
/// - 现在的「打开 ROM」是单文件 SAF，每次都要点一遍选择器；
/// - ROM 放在一个固定目录里更接近真实改版工作流（改一个、存回原处、再打开）；
/// - MCP 侧也能直接把「工作区里有哪些 ROM」告诉 AI，AI 才能自己挑基底。
///
/// 目录授权由原生 `ACTION_OPEN_DOCUMENT_TREE` + 持久授权完成，重启后仍有效；
/// 目录本身记在 `filesDir/workspace`（原生侧），Dart 侧每次启动问一次即可。
class ExternalWorkspace {
  static final ExternalWorkspace instance = ExternalWorkspace._();

  ExternalWorkspace._();

  WorkspaceDir? _dir;

  /// 当前工作区目录；未设置时为 null。
  WorkspaceDir? get dir => _dir;

  bool get configured => _dir != null;

  /// 上次读取失败的原因（授权失效/目录被删等）。界面用它提示「需要重新选目录」。
  String? lastError;

  /// 读取已保存的工作区目录（启动时调用一次）。
  Future<WorkspaceDir?> load() async {
    try {
      final raw = await _channel.invokeMethod<Object>('workspaceDir');
      _dir = WorkspaceDir.fromMap(raw);
      // 原生侧已把「授权失效」转成 null 并清掉记录，这里同步清空
      if (_dir == null) lastError = null;
      return _dir;
    } on MissingPluginException {
      return null;
    } catch (e) {
      lastError = _friendly(e);
      _dir = null;
      AppLog.instance.log('warn', '读取工作区目录失败: $lastError');
      return null;
    }
  }

  /// 把平台异常翻译成用户能照着做的说法。
  static String _friendly(Object e) {
    final text = e.toString();
    final lower = text.toLowerCase();
    if (text.contains('Invalid Uri') ||
        lower.contains('permission') ||
        text.contains('SecurityException')) {
      return '工作区目录的访问授权已失效（或在系统设置里被撤销），请重新选择目录。';
    }
    if (text.contains('Unsupported Uri')) {
      return '这个目录不支持访问，请换一个目录（如「文档」或 SD 卡根目录下的文件夹）。';
    }
    return text;
  }

  /// 弹出系统目录选择器；用户取消返回 null。
  ///
  /// 抛异常表示选择失败（如目录不支持长期授权）；调用方负责提示。
  Future<WorkspaceDir?> pick() async {
    try {
      final raw = await _channel.invokeMethod<Object>('pickWorkspaceDir');
      final d = WorkspaceDir.fromMap(raw);
      if (d != null) {
        _dir = d;
        lastError = null;
        AppLog.instance.log('info', '外部工作区已设为 ${d.name}');
      }
      return d;
    } catch (e) {
      lastError = _friendly(e);
      AppLog.instance.log('error', '选择工作区目录失败: $lastError');
      rethrow;
    }
  }

  /// 取消工作区（撤销授权）。
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<bool>('clearWorkspaceDir');
    } on MissingPluginException {
      // 测试环境
    }
    _dir = null;
  }

  /// 列出工作区里的 ROM 文件（按文件名排序；未设置目录时为空）。
  Future<List<WorkspaceRom>> listRoms() async {
    if (_dir == null) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('listWorkspaceRoms');
      if (raw == null) return const [];
      final out = <WorkspaceRom>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final name = item['name'] as String?;
        if (name == null || name.isEmpty) continue;
        out.add(WorkspaceRom(
          name: name,
          size: (item['size'] as num?)?.toInt() ?? -1,
          modified: (item['modified'] as num?)?.toInt() ?? 0,
        ));
      }
      return out;
    } on MissingPluginException {
      return const [];
    } catch (e) {
      AppLog.instance.log('error', '列出工作区 ROM 失败: $e');
      return const [];
    }
  }

  /// 读工作区里的一个 ROM（原名读取，不经过缓存副本）。
  Future<Uint8List?> readRom(String name) async {
    try {
      final bytes =
          await _channel.invokeMethod<Uint8List>('readWorkspaceRom', {'name': name});
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (e) {
      AppLog.instance.log('error', '读取工作区 ROM「$name」失败: $e');
      return null;
    }
  }

  /// 把修改结果写回工作区里的同名文件；成功返回 true。
  Future<bool> writeRom(String name, Uint8List bytes) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
          'writeWorkspaceRom', {'name': name, 'bytes': bytes});
      if (ok == true) {
        AppLog.instance.log('info', '已写回工作区「$name」(${bytes.length} 字节)');
      }
      return ok == true;
    } catch (e) {
      AppLog.instance.log('error', '写回工作区 ROM「$name」失败: $e');
      return false;
    }
  }
}

/// 便捷转发（界面层用）。
Future<WorkspaceDir?> pickWorkspaceDir() => ExternalWorkspace.instance.pick();

/// 是否可用外部工作区（无原生通道的测试环境返回 false）。
Future<bool> workspaceSupported() async {
  try {
    await _channel.invokeMethod<Object>('workspaceDir');
    return true;
  } on MissingPluginException {
    return false;
  } catch (_) {
    return true;
  }
}
