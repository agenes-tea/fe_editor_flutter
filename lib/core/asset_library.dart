import 'package:flutter/services.dart';

import 'app_log.dart';
import 'external_workspace.dart' show WorkspaceDir, WorkspaceRom;

const _channel = MethodChannel('fe_editor/files');

/// 素材库里的一个文件（肖像 PNG、战斗动画帧、图标等）。
///
/// 与 [WorkspaceRom] 同构，但语义是「素材」而不是「ROM」——
/// 两者存在**不同的授权目录**里，互不干扰。
typedef AssetFile = WorkspaceRom;

/// 素材库：用户指定一个设备目录，导出素材时直接写进去、下次从列表里挑。
///
/// 为什么单独开一个目录而不复用外部工作区：
/// - 工作区只装 ROM，`listWorkspaceRoms` 按 `.gba/.agb/.bin` 过滤，
///   混进素材会把 ROM 列表搅乱；
/// - 素材与 ROM 是两件不同的事，用户可能只想给其中一个授权。
///
/// 目录授权走 SAF `ACTION_OPEN_DOCUMENT_TREE` + 持久授权，重启后仍有效。
class AssetLibrary {
  static final AssetLibrary instance = AssetLibrary._();

  AssetLibrary._();

  WorkspaceDir? _dir;

  /// 当前素材库目录；未设置时为 null。
  WorkspaceDir? get dir => _dir;

  bool get configured => _dir != null;

  /// 上次读取失败的原因（授权失效等）。界面据此提示「需要重新选目录」。
  String? lastError;

  /// 读取已保存的素材库目录（启动时调用一次）。
  Future<WorkspaceDir?> load() async {
    try {
      final raw = await _channel.invokeMethod<Object>('assetDir');
      _dir = WorkspaceDir.fromMap(raw);
      if (_dir == null) lastError = null;
      return _dir;
    } on MissingPluginException {
      return null;
    } catch (e) {
      lastError = _friendly(e);
      _dir = null;
      AppLog.instance.log('warn', '读取素材库目录失败: $lastError');
      return null;
    }
  }

  static String _friendly(Object e) {
    final text = e.toString();
    final lower = text.toLowerCase();
    if (text.contains('Invalid Uri') ||
        lower.contains('permission') ||
        text.contains('SecurityException')) {
      return '素材库目录的访问授权已失效（或在系统设置里被撤销），请重新选择目录。';
    }
    if (text.contains('Unsupported Uri')) {
      return '这个目录不支持访问，请换一个目录（如「文档」或 SD 卡根目录下的文件夹）。';
    }
    return text;
  }

  /// 弹出系统目录选择器；用户取消返回 null。
  Future<WorkspaceDir?> pick() async {
    try {
      final raw = await _channel.invokeMethod<Object>('pickAssetDir');
      final d = WorkspaceDir.fromMap(raw);
      if (d != null) {
        _dir = d;
        lastError = null;
        AppLog.instance.log('info', '素材库已设为 ${d.name}');
      }
      return d;
    } catch (e) {
      lastError = _friendly(e);
      AppLog.instance.log('error', '选择素材库目录失败: $lastError');
      rethrow;
    }
  }

  /// 取消素材库（撤销授权）。
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<bool>('clearAssetDir');
    } on MissingPluginException {
      // 测试环境
    }
    _dir = null;
  }

  /// 列出素材库里的文件（按文件名排序；未设置目录时为空）。
  ///
  /// 不过滤扩展名：素材库是用户自己的目录，图片、补丁、笔记都可能放进来。
  Future<List<AssetFile>> list() async {
    if (_dir == null) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('listAssets');
      if (raw == null) return const [];
      final out = <AssetFile>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final name = item['name'] as String?;
        if (name == null || name.isEmpty) continue;
        out.add(AssetFile(
          name: name,
          size: (item['size'] as num?)?.toInt() ?? -1,
          modified: (item['modified'] as num?)?.toInt() ?? 0,
        ));
      }
      return out;
    } on MissingPluginException {
      return const [];
    } catch (e) {
      AppLog.instance.log('error', '列出素材失败: $e');
      return const [];
    }
  }

  /// 读素材库里的一个文件。
  Future<Uint8List?> read(String name) async {
    try {
      final bytes =
          await _channel.invokeMethod<Uint8List>('readAsset', {'name': name});
      if (bytes == null || bytes.isEmpty) return null;
      return bytes;
    } catch (e) {
      AppLog.instance.log('error', '读取素材「$name」失败: $e');
      return null;
    }
  }

  /// 把一份素材写进素材库；同名**原地覆盖**（不会攒出 `foo (1).png`）。
  Future<bool> write(String name, Uint8List bytes) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('writeAsset', {'name': name, 'bytes': bytes});
      if (ok == true) {
        AppLog.instance.log('info', '已存入素材库「$name」(${bytes.length} 字节)');
      }
      return ok == true;
    } catch (e) {
      lastError = _friendly(e);
      AppLog.instance.log('error', '写入素材「$name」失败: $lastError');
      return false;
    }
  }
}

/// 便捷转发（界面层用）。
Future<WorkspaceDir?> pickAssetDir() => AssetLibrary.instance.pick();

/// 是否可用素材库（无原生通道的测试环境返回 false）。
Future<bool> assetLibrarySupported() async {
  try {
    await _channel.invokeMethod<Object>('assetDir');
    return true;
  } on MissingPluginException {
    return false;
  } catch (_) {
    return true;
  }
}
