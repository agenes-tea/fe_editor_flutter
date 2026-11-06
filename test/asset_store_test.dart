import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fe_editor/core/asset_store.dart';

/// 内存文件系统：让 AssetStore 的纯逻辑能脱离原生通道单测。
class MemAssetFs implements AssetFs {
  final Map<String, Map<String, Uint8List>> files = {};
  final List<String> log = [];

  Map<String, Uint8List> _dir(String d) => files.putIfAbsent(d, () => {});

  @override
  Future<List<String>> list(String dir) async =>
      _dir(dir).keys.toList()..sort();

  @override
  Future<Uint8List?> read(String dir, String name) async => _dir(dir)[name];

  @override
  Future<bool> write(String dir, String name, Uint8List bytes) async {
    log.add('write $dir/$name');
    _dir(dir)[name] = bytes;
    return true;
  }

  @override
  Future<bool> delete(String dir, String name) async {
    _dir(dir).remove(name);
    return true;
  }

  @override
  Future<Map<String, Object?>?> importFromLibrary(
      String dir, String name) async {
    throw UnimplementedError('单测不测原生搬运');
  }
}

Uint8List _bytes(int n, {int seed = 1}) =>
    Uint8List.fromList(List.generate(n, (i) => (i * seed) & 0xFF));

void main() {
  group('AssetStore handle 语义', () {
    test('同内容得到同一个 handle，不同内容不同', () {
      final a = AssetStore.handleOf(_bytes(64));
      final b = AssetStore.handleOf(_bytes(64));
      final c = AssetStore.handleOf(_bytes(64, seed: 2));
      expect(a, b);
      expect(a, isNot(c));
      expect(a.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(a), isTrue);
    });

    test('任意长度都不崩（空/1 字节/短于采样窗口）', () {
      expect(AssetStore.handleOf(Uint8List(0)), hasLength(16));
      expect(AssetStore.handleOf(Uint8List.fromList([1])), hasLength(16));
      expect(AssetStore.handleOf(_bytes(15)), hasLength(16));
      expect(AssetStore.handleOf(_bytes(16)), hasLength(16));
    });
  });

  group('AssetStore 入库与元数据', () {
    test('put 后可 list/info，且元数据不含内容', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      final a = await store.put(_bytes(100),
          type: 'image', mime: 'image/png', sourceName: 'x.png');

      final listed = await store.list();
      expect(listed, hasLength(1));
      expect(listed.first.handle, a.handle);
      expect(listed.first.size, 100);

      final json = a.toJson();
      // 硬纪律：给 AI 的元数据里永远不能有内容字段
      expect(json.containsKey('base64'), isFalse);
      expect(json.containsKey('bytes'), isFalse);
      expect(json.containsKey('data'), isFalse);
      expect(json['handle'], a.handle);
    });

    test('同内容重复 put 只占一份，并补全元数据', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      final first = await store.put(_bytes(50), type: 'binary');
      final second = await store.put(_bytes(50), type: 'image', mime: 'image/png');

      expect(second.handle, first.handle);
      expect(await store.totalBytes(), 50);
      expect((await store.list()), hasLength(1));
      // 后一次带了更具体的类型，应被采纳
      expect((await store.info(first.handle))!.type, 'image');
    });

    test('按 type 过滤', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      await store.put(_bytes(10, seed: 1), type: 'image');
      await store.put(_bytes(10, seed: 2), type: 'map_plan');
      expect(await store.list(type: 'image'), hasLength(1));
      expect(await store.list(type: 'map_plan'), hasLength(1));
      expect(await store.list(), hasLength(2));
    });

    test('元数据能持久化并重新加载（同目录新实例）', () async {
      final fs = MemAssetFs();
      final s1 = AssetStore(project: 'abc', fs: fs);
      final a = await s1.put(_bytes(77), type: 'image', sourceName: 'p.png');

      final s2 = AssetStore(project: 'abc', fs: fs);
      final again = await s2.info(a.handle);
      expect(again, isNotNull);
      expect(again!.size, 77);
      expect(again.sourceName, 'p.png');
      expect(again.type, 'image');
    });

    test('项目互相隔离（不同 project 目录互不可见）', () async {
      final fs = MemAssetFs();
      final one = AssetStore(project: 'p1', fs: fs);
      final two = AssetStore(project: 'p2', fs: fs);
      await one.put(_bytes(20));
      expect(await one.list(), hasLength(1));
      expect(await two.list(), isEmpty);
    });
  });

  group('AssetStore 容量与引用', () {
    test('超容量拒绝并给出可读提示', () async {
      final fs = MemAssetFs();
      final store =
          AssetStore(project: 'abc', fs: fs, maxTotalBytes: 100);
      await store.put(_bytes(60));
      await expectLater(
        store.put(_bytes(60, seed: 3)),
        throwsA(isA<AssetStoreException>()
            .having((e) => e.code, 'code', 'quota_exceeded')),
      );
    });

    test('有引用时删除被拒绝，force 才删', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      final a = await store.put(_bytes(30));
      await store.addRef(a.handle, 'FE7J:portrait:11');

      await expectLater(
        store.delete(a.handle),
        throwsA(isA<AssetStoreException>()
            .having((e) => e.code, 'code', 'referenced')),
      );
      expect(await store.list(), hasLength(1));

      await store.delete(a.handle, force: true);
      expect(await store.list(), isEmpty);
    });

    test('重复 addRef 不产生重复项', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      final a = await store.put(_bytes(30));
      await store.addRef(a.handle, 'r1');
      await store.addRef(a.handle, 'r1');
      expect((await store.info(a.handle))!.refs, ['r1']);
    });

    test('addRef 到不存在的素材要报错，不能静默丢弃', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      await expectLater(
        store.addRef('0000000000000000', 'FE7J:portrait:1'),
        throwsA(isA<AssetStoreException>()
            .having((e) => e.code, 'code', 'not_found')),
      );
    });

    test('删除不存在的 handle 报 not_found', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      await expectLater(
        store.delete('deadbeefdeadbeef'),
        throwsA(isA<AssetStoreException>()
            .having((e) => e.code, 'code', 'not_found')),
      );
    });

    test('空内容拒绝入库', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'abc', fs: fs);
      await expectLater(
        store.put(Uint8List(0)),
        throwsA(isA<AssetStoreException>()
            .having((e) => e.code, 'code', 'empty')),
      );
    });
  });

  group('AssetStore 首次访问（回归：空素材库不能报错）', () {
    test('从未写入过时 load/list/info 都正常', () async {
      final fs = MemAssetFs();
      final store = AssetStore(project: 'fresh', fs: fs);
      // 目录里什么都没有：_meta.json 不存在，读它必须拿到 null 而不是抛异常
      await store.load();
      expect(await store.list(), isEmpty);
      expect(await store.list(type: 'image'), isEmpty);
      expect(await store.info('0000000000000000'), isNull);
      expect(await store.totalBytes(), 0);
      expect(await store.read('0000000000000000'), isNull);
    });

    test('读取不存在的 meta 时 fs 返回 null 而不是抛异常', () async {
      final fs = MemAssetFs();
      // 模拟原生侧行为：文件不存在 → null
      expect(await fs.read('assets/fresh', '_meta.json'), isNull);
    });
  });
}
