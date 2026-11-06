import 'dart:convert';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'asset_converters.dart';
import 'rom_buffer.dart' show crc32;

/// 一次素材入库后的结果。
class StoredAsset {
  /// 内容哈希前 16 位十六进制。**AI 侧唯一能看到的引用**。
  final String handle;

  /// 素材类型：portrait_sheet / battle_anim_frame / image / map_plan / audio / binary。
  final String type;

  /// 磁盘上的文件名（`<handle>.bin`）。
  final String file;

  final int size;
  final String mime;

  /// 图片类素材才有；非图片为 0。
  final int width;
  final int height;

  /// 创建时间（毫秒时间戳）。
  final int created;

  /// 来源：workspace / upload / export / converter。
  final String origin;

  /// 原始文件名（如 portrait_011.png），仅用于展示。
  final String sourceName;

  /// 被哪些 ROM 槽位引用（`FE7J:portrait:11`），删除前查它。
  final List<String> refs;

  const StoredAsset({
    required this.handle,
    required this.type,
    required this.file,
    required this.size,
    required this.mime,
    this.width = 0,
    this.height = 0,
    required this.created,
    required this.origin,
    this.sourceName = '',
    this.refs = const [],
  });

  /// 给 AI 看的元数据：**永远不含内容**（不返回 base64 是硬纪律）。
  Map<String, Object?> toJson() => {
        'handle': handle,
        'type': type,
        'size': size,
        'mime': mime,
        if (width > 0) 'width': width,
        if (height > 0) 'height': height,
        'created': created,
        'origin': origin,
        if (sourceName.isNotEmpty) 'source_name': sourceName,
        if (refs.isNotEmpty) 'refs': refs,
      };

  Map<String, Object?> toMetaJson() => {
        ...toJson(),
        'file': file,
      };

  StoredAsset copyWith({
    String? type,
    int? width,
    int? height,
    String? sourceName,
    List<String>? refs,
  }) =>
      StoredAsset(
        handle: handle,
        type: type ?? this.type,
        file: file,
        size: size,
        mime: mime,
        width: width ?? this.width,
        height: height ?? this.height,
        created: created,
        origin: origin,
        sourceName: sourceName ?? this.sourceName,
        refs: refs ?? this.refs,
      );

  static StoredAsset? fromJson(Map<String, Object?> m) {
    final h = m['handle'] as String?;
    final f = m['file'] as String?;
    if (h == null || h.isEmpty) return null;
    return StoredAsset(
      handle: h,
      type: (m['type'] as String?) ?? 'binary',
      file: (f == null || f.isEmpty) ? '$h.bin' : f,
      size: (m['size'] as num?)?.toInt() ?? 0,
      mime: (m['mime'] as String?) ?? 'application/octet-stream',
      width: (m['width'] as num?)?.toInt() ?? 0,
      height: (m['height'] as num?)?.toInt() ?? 0,
      created: (m['created'] as num?)?.toInt() ?? 0,
      origin: (m['origin'] as String?) ?? 'unknown',
      sourceName: (m['source_name'] as String?) ?? '',
      refs: [for (final r in (m['refs'] as List?) ?? const []) r.toString()],
    );
  }
}

/// 素材存储被拒绝的原因（调用方据此给用户/AI 可照做的提示）。
class AssetStoreException implements Exception {
  final String code;
  final String message;

  const AssetStoreException(this.code, this.message);

  @override
  String toString() => message;
}

/// 磁盘层：一个项目的素材都住在同一个目录里，一个文件 = 一份内容。
///
/// 为什么把「读目录 / 写文件 / 列表」抽成接口而不是直接调 MethodChannel：
/// 纯 Dart 单测要能跑（测试环境没有原生通道），原生实现只在真机上装。
/// 这是本文件唯一的抽象，**不要把业务逻辑塞进实现里**。
abstract class AssetFs {
  /// 列出目录里的文件名（不递归）。
  Future<List<String>> list(String dir);

  Future<Uint8List?> read(String dir, String name);

  Future<bool> write(String dir, String name, Uint8List bytes);

  Future<bool> delete(String dir, String name);

  /// 把 SAF 素材库里的文件直接搬进 AssetStore 目录。
  ///
  /// 走原生实现：字节不经 Dart、不进 AI 上下文，所以 1MB 也能一步入库。
  /// 返回 `{handle, size, source_name}`；素材库未设置时抛异常。
  Future<Map<String, Object?>?> importFromLibrary(String dir, String name);
}

/// [AssetFs] 的原生实现：走已有的 `fe_editor/files` 通道。
class NativeAssetFs implements AssetFs {
  const NativeAssetFs();

  static const _channel = MethodChannel('fe_editor/files');

  @override
  Future<List<String>> list(String dir) async {
    final raw = await _channel
        .invokeMethod<List<Object?>>('listAssetStore', {'dir': dir});
    return [for (final e in raw ?? const []) e.toString()];
  }

  @override
  Future<Uint8List?> read(String dir, String name) async {
    return _channel
        .invokeMethod<Uint8List>('readAssetStore', {'dir': dir, 'name': name});
  }

  @override
  Future<bool> write(String dir, String name, Uint8List bytes) async {
    final ok = await _channel.invokeMethod<bool>(
        'writeAssetStore', {'dir': dir, 'name': name, 'bytes': bytes});
    return ok == true;
  }

  @override
  Future<bool> delete(String dir, String name) async {
    final ok = await _channel
        .invokeMethod<bool>('deleteAssetStore', {'dir': dir, 'name': name});
    return ok == true;
  }

  @override
  Future<Map<String, Object?>?> importFromLibrary(
      String dir, String name) async {
    final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'importAssetFromLibrary', {'dir': dir, 'name': name});
    if (raw == null) return null;
    return {
      for (final e in raw.entries) e.key.toString(): e.value,
    };
  }
}

/// 项目级素材仓库（AssetStore）。
///
/// 三层架构里的持久层：**所有二进制住在这里**，上层只拿 handle。
/// - 项目 ID = ROM 指纹（复用已有的 `FeRom.fingerprint` 语义，
///   与自定义名单按指纹隔离是同一套约定，不引入新的「项目」概念）。
/// - handle = 内容哈希前 16 位，天然去重、天然可校验。
/// - 内容与元数据分开存：`<handle>.bin` + `_meta.json`（一个目录一份索引）。
class AssetStore {
  AssetStore({
    required this.project,
    AssetFs fs = const NativeAssetFs(),
    this.root = 'assets',
    this.maxTotalBytes = 100 * 1024 * 1024,
  }) : _fs = fs;

  /// 项目 ID（ROM 指纹的十六进制）。
  final String project;

  /// 素材根目录，原生侧展开为 `filesDir/<root>/<project>/`。
  final String root;

  /// 容量上限（默认 100MB）。满了拒绝导入，不静默失败。
  final int maxTotalBytes;

  final AssetFs _fs;

  String get _dir => '$root/$project';

  final Map<String, StoredAsset> _assets = {};
  bool _loaded = false;

  /// 计算内容 handle：前 8 位 = crc32，后 8 位 = 长度与首尾采样哈希。
  ///
  /// 不用完整 SHA 的理由：项目零第三方依赖，crc32 已在 `rom_buffer.dart`。
  /// 单用 32 位 crc 在几千份素材下碰撞概率不高但不算低；
  /// 拼上「长度 + 首尾采样」，同一 crc 的热门小文件（如全 0 图）也能区分开。
  static String handleOf(Uint8List bytes) {
    final c = crc32(bytes);
    final head = bytes.length >= 16
        ? bytes.sublist(0, 8)
        : bytes;
    final tail = bytes.length >= 16
        ? bytes.sublist(bytes.length - 8)
        : const <int>[];
    final sample = <int>[...head, ...tail, bytes.length & 0xFF,
      (bytes.length >> 8) & 0xFF, (bytes.length >> 16) & 0xFF];
    final c2 = crc32(Uint8List.fromList(sample));
    return c.toRadixString(16).padLeft(8, '0') +
        c2.toRadixString(16).padLeft(8, '0');
  }

  /// 读元数据索引（幂等，首次调用后才读盘）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final raw = await _fs.read(_dir, '_meta.json');
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(utf8.decode(raw));
      if (m is! Map) return;
      for (final e in (m['assets'] as Map?)?.entries ?? const <MapEntry>[]) {
        final a = StoredAsset.fromJson(Map<String, Object?>.from(e.value as Map));
        if (a != null) _assets[a.handle] = a;
      }
    } catch (e) {
      AppLog.instance.log('warn', '素材索引解析失败（忽略旧索引）: $e');
    }
  }

  /// 已存放的素材（按创建时间倒序）。
  Future<List<StoredAsset>> list({String? type}) async {
    await load();
    final out = _assets.values
        .where((a) => type == null || a.type == type)
        .toList()
      ..sort((a, b) => b.created.compareTo(a.created));
    return out;
  }

  Future<StoredAsset?> info(String handle) async {
    await load();
    return _assets[handle];
  }

  Future<int> totalBytes() async {
    await load();
    return _assets.values.fold<int>(0, (s, a) => s + a.size);
  }

  /// 把 SAF 素材库里的一个文件搬进本项目 AssetStore。
  ///
  /// **字节全部在原生侧走**（素材库 → filesDir/assets），Dart 只收 handle
  /// 与尺寸。这就是「1MB 图也能入库」的通路：不经过 AI 上下文。
  Future<StoredAsset> importFromLibrary(String name) async {
    await load();
    final used = _assets.values.fold<int>(0, (s, a) => s + a.size);
    if (used >= maxTotalBytes) {
      throw AssetStoreException(
        'quota_exceeded',
        '素材库已满（${(used / 1048576).toStringAsFixed(0)}MB），请先删除不再需要的素材。',
      );
    }
    final Map<String, Object?>? res;
    try {
      res = await _fs.importFromLibrary(_dir, name);
    } catch (e) {
      throw AssetStoreException('import_failed', '从素材库导入「$name」失败：$e');
    }
    if (res == null) {
      throw AssetStoreException('import_failed', '从素材库导入「$name」失败');
    }
    final handle = (res['handle'] as String?) ?? '';
    if (handle.isEmpty) {
      throw const AssetStoreException('import_failed', '导入后没有拿到 handle');
    }
    final size = (res['size'] as num?)?.toInt() ?? 0;
    if (used + size > maxTotalBytes) {
      await _fs.delete(_dir, '$handle.bin');
      throw AssetStoreException(
        'quota_exceeded',
        '再加 ${(size / 1024).toStringAsFixed(0)}KB 会超过素材库上限，已放弃本次导入。',
      );
    }
    final existing = _assets[handle];
    if (existing != null) return existing;
    final asset = StoredAsset(
      handle: handle,
      type: Converters.typeOfName(name),
      file: '$handle.bin',
      size: size,
      mime: Converters.mimeOfName(name),
      created: DateTime.now().millisecondsSinceEpoch,
      origin: 'library',
      sourceName: name,
    );
    _assets[handle] = asset;
    await _saveMeta();
    return asset;
  }

  /// 读内容。**这是唯一拿得到字节的入口，且不给 AI 用**（MCP 不暴露它）。
  Future<Uint8List?> read(String handle) async {
    final a = await info(handle);
    if (a == null) return null;
    return _fs.read(_dir, a.file);
  }

  /// 内容入库。同内容（同 handle）直接复用，不重复占空间。
  ///
  /// 抛 [AssetStoreException]：超容量 / 写盘失败。返回的 handle 不含内容。
  Future<StoredAsset> put(
    Uint8List bytes, {
    String type = 'binary',
    String mime = 'application/octet-stream',
    int width = 0,
    int height = 0,
    String origin = 'upload',
    String sourceName = '',
    List<String> refs = const [],
  }) async {
    await load();
    if (bytes.isEmpty) {
      throw const AssetStoreException('empty', '内容为空，没有可存的素材');
    }
    final handle = handleOf(bytes);
    final existing = _assets[handle];
    if (existing != null) {
      // 同内容已存在：只补元数据（例如同一张图先当 image 存、后按肖像引用）
      final merged = existing.copyWith(
        type: existing.type == 'binary' ? type : null,
        width: existing.width == 0 ? width : null,
        height: existing.height == 0 ? height : null,
        sourceName: existing.sourceName.isEmpty ? sourceName : null,
      );
      _assets[handle] = merged;
      await _saveMeta();
      return merged;
    }
    final used = _assets.values.fold<int>(0, (s, a) => s + a.size);
    if (used + bytes.length > maxTotalBytes) {
      throw AssetStoreException(
        'quota_exceeded',
        '素材库已占用 ${(used / 1048576).toStringAsFixed(1)}MB，'
            '再加 ${(bytes.length / 1024).toStringAsFixed(0)}KB 会超过上限 '
            '${(maxTotalBytes / 1048576).toStringAsFixed(0)}MB。'
            '请先删除不再需要的素材再导入。',
      );
    }
    final file = '$handle.bin';
    final ok = await _fs.write(_dir, file, bytes);
    if (!ok) {
      throw const AssetStoreException('write_failed', '写入素材文件失败');
    }
    final asset = StoredAsset(
      handle: handle,
      type: type,
      file: file,
      size: bytes.length,
      mime: mime,
      width: width,
      height: height,
      created: DateTime.now().millisecondsSinceEpoch,
      origin: origin,
      sourceName: sourceName,
      refs: refs,
    );
    _assets[handle] = asset;
    await _saveMeta();
    return asset;
  }

  /// 登记引用（把素材挂到某个 ROM 槽位，删除前据此拦截）。
  Future<void> addRef(String handle, String ref) async {
    await load();
    final a = _assets[handle];
    if (a == null) {
      // 静默忽略会让「有引用、无素材」这种不一致无声无息地留下来，
      // 删除时又因为查不到记录而拦不住。直接报错。
      throw AssetStoreException('not_found', '没有 handle 为「$handle」的素材，无法登记引用');
    }
    if (a.refs.contains(ref)) return;
    _assets[handle] = a.copyWith(refs: [...a.refs, ref]);
    await _saveMeta();
  }

  /// 删除。有引用时默认拒绝（`force=false`），避免删掉某个 ROM 正在用的素材。
  Future<void> delete(String handle, {bool force = false}) async {
    await load();
    final a = _assets[handle];
    if (a == null) {
      throw const AssetStoreException('not_found', '没有这个素材');
    }
    if (!force && a.refs.isNotEmpty) {
      throw AssetStoreException(
        'referenced',
        '素材 $handle 仍被引用：${a.refs.join('、')}。'
            '确实要删请传 force=true（会让那些槽位失去来源）。',
      );
    }
    await _fs.delete(_dir, a.file);
    _assets.remove(handle);
    await _saveMeta();
  }

  Future<void> _saveMeta() async {
    final body = jsonEncode({
      'schema': 1,
      'project': project,
      'assets': {
        for (final a in _assets.values) a.handle: a.toMetaJson(),
      },
    });
    await _fs.write(_dir, '_meta.json', Uint8List.fromList(utf8.encode(body)));
  }
}
