import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/asset_library.dart';
import '../core/battle_anim.dart' show encodePng;
import '../core/editable_rom.dart';
import '../core/file_picker_service.dart';
import '../core/fe_rom.dart';
import '../core/portrait.dart';
import '../core/portrait_import.dart';
import '../core/portrait_porter.dart';
import 'portrait_page.dart' show PortraitImageCache, PortraitView;
import 'portrait_quant_row.dart';

/// 从文件解码出一张 RGBA8 图。
///
/// `instantiateImageCodec` 是异步的，所以图片解码只能留在界面层；
/// 核心层的 [PortraitImporter] 只接受裸 RGBA，测试里可以直接喂数组。
Future<_DecodedImage?> _decodeImage(String path) async {
  try {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = img.width;
    final h = img.height;
    img.dispose();
    codec.dispose();
    if (data == null) return null;
    return _DecodedImage(data.buffer.asUint8List(), w, h);
  } catch (_) {
    return null;
  }
}

class _DecodedImage {
  final Uint8List rgba;
  final int width;
  final int height;
  _DecodedImage(this.rgba, this.width, this.height);
}

/// 肖像编辑器：把外部图片转成游戏中可识别的人物肖像。
///
/// 只替换目标条目的**正脸与调色板**；地图头像 / 嘴型 / 眼睛帧保持原样，
/// 界面上要写明这一点，否则用户会以为地图上的小头像也跟着换了。
class PortraitImportPage extends StatefulWidget {
  final EditableRom edit;

  /// 预选的目标肖像 ID（从容肖像列表进来时带上）。
  final int? initialTargetId;

  const PortraitImportPage({super.key, required this.edit, this.initialTargetId});

  @override
  State<PortraitImportPage> createState() => _PortraitImportPageState();
}

class _PortraitImportPageState extends State<PortraitImportPage> {
  late PortraitReader _reader = PortraitReader(widget.edit.liveRom);

  String? _sourceName;
  _DecodedImage? _source;
  PortraitImportResult? _result;
  List<PortraitQuantVariant>? _variants;
  PortraitQuantStrategy _strategy = PortraitQuantStrategy.classic;
  String? _error;

  PortraitFit _fit = PortraitFit.contain;
  /// 嘴型处理方式：real 带真实帧 / fixed 全帧相同 / none 不写（FE6 做不到）。
  PortraitFrameMode _mouthMode = PortraitFrameMode.real;
  /// 眨眼处理方式。FE6 没有 eye 字段，这一项在封印之剑上不生效。
  PortraitFrameMode _blinkMode = PortraitFrameMode.real;
  bool _includeMapFace = true;

  bool get _isFe6 => widget.edit.rom.table.portraitDataSize == 16;
  int? _targetId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialTargetId;
    if (initial != null && initial >= 0 && initial < _reader.entryCount) {
      _targetId = initial;
    } else if (_reader.entryCount > 0) {
      // 没指定目标时优先落到第一条有图的条目：
      // 第 0 条通常是空槽（无图），默认选它会让用户以为「写了但没变化」。
      _targetId = _firstWithImage();
    }
  }

  int _firstWithImage() {
    for (var i = 0; i < _reader.entryCount; i++) {
      if (_reader.hasImage(i)) return i;
    }
    return 0;
  }

  @override
  void dispose() {
    _reader.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final path = await pickImageFile();
    if (path == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final img = await _decodeImage(path);
    if (!mounted) return;
    if (img == null) {
      setState(() {
        _busy = false;
        _error = '这张图片读不出来，换一张 PNG / JPG 试试';
      });
      return;
    }
    setState(() {
      _source = img;
      _sourceName = path.split('/').last;
      _busy = false;
    });
    _reconvert();
  }

  void _reconvert() {
    final src = _source;
    if (src == null) return;
    final target = _targetId;
    final entry = target == null
        ? null
        : PortraitReader(widget.edit.rom).entryAt(target);
    try {
      final variants = PortraitImporter.convertAll(
        src.rgba,
        src.width,
        src.height,
        fe6: _isFe6,
        fit: _fit,
        mapFace: _includeMapFace,
        mouthX: entry?.mouthX,
        mouthY: entry?.mouthY,
        mouthMode: _mouthMode,
        blinkMode: _blinkMode,
      );
      final chosen = variants
          .firstWhere((v) => v.strategy == _strategy)
          .result;
      setState(() {
        _variants = variants;
        _result = chosen;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _variants = null;
        _result = null;
        _error = '转换失败：$e';
      });
    }
  }

  /// 点选一种量化风格：只切换选中项（4 张已算好，不必重算），并让 [_result] 指向它。
  void _selectStrategy(PortraitQuantStrategy s) {
    final vs = _variants;
    if (vs == null) return;
    setState(() {
      _strategy = s;
      _result = vs.firstWhere((v) => v.strategy == s).result;
    });
  }

  /// 写入前确认弹窗里的「表情会怎么处理」说明。
  ///
  /// 把用户选的三档翻译成他在游戏里实际会看到的效果，包括两种做不到的情况
  /// （FE6 的「无嘴型」会退回固定；普通图选「真实帧」实际写的是固定）。
  String _applySummary() {
    final r = _result;
    final lines = <String>[];
    final mouth = r?.mouthMode ?? _mouthMode;
    switch (mouth) {
      case PortraitFrameMode.real:
        lines.add(_isFe6
            ? '嘴型：按这条肖像的嘴部坐标重画新脸的嘴（封印之剑的嘴型帧画在正脸图里）。'
            : '嘴型：写入素材图自带的 6 帧，对话时嘴会开合。');
      case PortraitFrameMode.fixed:
        lines.add('嘴型：固定（所有帧用同一块画面，游戏里嘴不动）。');
      case PortraitFrameMode.none:
        lines.add(_isFe6
            ? '嘴型：封印之剑做不到「无嘴型」，会写成固定（否则那块还是旧角色的嘴）。'
            : '嘴型：指针置 0，不显示嘴型帧。');
    }
    if (_isFe6) {
      lines.add('眨眼：封印之剑没有眨眼帧，不适用。');
    } else {
      lines.add(r?.blinkMode == PortraitFrameMode.real
          ? '眨眼：写入素材图自带的两张眼型帧，会眨眼。'
          : '眨眼：固定（两张眼型相同，不眨眼）。');
    }
    lines.add('嘴型/眼睛与正脸共用同一套调色板，不会串色。');
    return lines.join('\n');
  }

  Future<void> _apply() async {
    final result = _result;
    final target = _targetId;
    if (result == null || target == null) return;

    // 提前扫描引用单位，方便在弹窗里提示
    final affectingUnits = _reader.unitIndicesForPortrait(target);
    final unitNames = <String>[];
    for (final i in affectingUnits) {
      final n = widget.edit.liveRom.unitDisplayName(i).trim();
      unitNames.add(n.isEmpty ? '角色 $i' : n);
    }
    final unitHint = unitNames.isEmpty
        ? '⚠️ 没有角色引用这条肖像，写入后游戏内不会自动显示新脸。\n'
            '如需让特定角色使用，请在角色页手动改 face 字段，或点击「同步角色」按钮。\n\n'
        : '将影响以下 ${unitNames.length} 个角色：${unitNames.join('、')}\n\n';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('写入这张肖像？'),
        content: Text(
          '会替换第 $target 条肖像的'
          '${_includeMapFace ? '正脸、调色板与 32×32 小头像' : '正脸与调色板'}。\n\n'
          '${_applySummary()}\n\n'
          '${unitHint}写入后可用「撤销全部」整体还原。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('写入')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    final out = PortraitPorter(widget.edit).importFace(
      result,
      target,
      replaceMapFace: _includeMapFace,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!out.ok) {
      setState(() => _error = out.message);
      return;
    }
    // 缓存里旧的脸还在，读回核对前必须清掉
    PortraitImageCache.instance.invalidate();
    // _reader 是 late final，dispose 后不能再被 build 使用；
    // 重建一个指向同一份 liveRom 的 reader 才能刷出新写入的图。
    _reader.dispose();
    _reader = PortraitReader(widget.edit.liveRom);

    // 写出成功后：若有角色引用该条目，弹出同步对话框让他们确认关联；
    // 若无引用，提示用户可手动关联。
    final importedName = _reader.nameFor(target).trim();
    final syncResult = PortraitPorter(widget.edit)
        .syncUnitFaces(target, target);
    if (syncResult.changedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已写入第 $target 条肖像（${out.bytesWritten} 字节），'
              '${syncResult.changedCount} 个角色已自动关联。'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已写入第 $target 条肖像（${out.bytesWritten} 字节）。\n'
              '没有角色引用此条目，需在角色页手动关联 face 字段。'),
          action: SnackBarAction(
            label: '同步角色',
            onPressed: () => _showSyncUnitDialog(target),
          ),
        ),
      );
    }
    Navigator.pop(context, {'id': target, 'name': importedName});
    setState(() {});
  }

  /// 弹出肖像选择器：把指定单位的面部指向一个新肖像条目。
  void _showSyncUnitDialog(int currentPortraitId) {
    final units = _reader.unitIndicesForPortrait(currentPortraitId);
    if (units.isEmpty) return;
    // 收集所有有图的肖像条目
    final options = <int>[];
    for (var i = 0; i < _reader.entryCount; i++) {
      if (_reader.hasImage(i)) options.add(i);
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('同步角色肖像'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('已将第 $currentPortraitId 条肖像写入 ROM，但以下角色尚未关联：',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            ...units.map((i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• ${widget.edit.liveRom.unitDisplayName(i).trim().isEmpty ? "角色 $i" : widget.edit.liveRom.unitDisplayName(i)}',
                      style: const TextStyle(fontSize: 13)),
                )),
            const SizedBox(height: 12),
            Text('请选择要挂上的肖像（当前第 $currentPortraitId 条）：',
                style: TextStyle(fontSize: 13)),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              value: options.contains(currentPortraitId)
                  ? currentPortraitId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                for (final id in options)
                  DropdownMenuItem(
                    value: id,
                    child: Text(
                      '${_reader.nameFor(id).trim().isEmpty ? "肖像 #$id" : _reader.nameFor(id)} (#$id)',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
              onChanged: (v) async {
                if (v == null) return;
                Navigator.pop(ctx);
                await _syncUnitFaces(currentPortraitId, v);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消')),
        ],
      ),
    );
  }

  /// 把 [oldId] 的所有引用单位改为指向 [newId]。
  Future<void> _syncUnitFaces(int oldId, int newId) async {
    setState(() => _busy = true);
    final syncer = PortraitPorter(widget.edit);
    final result = syncer.syncUnitFaces(oldId, newId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('同步失败：${result.error}')),
      );
      return;
    }
    // 重建 reader 以刷新缓存
    _reader.dispose();
    _reader = PortraitReader(widget.edit.liveRom);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('已将 ${result.changedCount} 个角色的肖像同步到第 $newId 条（${result.changes.map((c) => c.unitName).join('、')}）')),
    );
    setState(() {});
  }

  /// 把量化后的肖像（96×80 预览，即游戏里实际会显示的样子）存进素材库。
  ///
  /// 存的是**量化后的结果**，不是原图：这样再导回游戏时能直接命中同一套
  /// 16 色调色板，不会再量化一次（二次量化会把颜色又拉偏一轮）。
  Future<void> _saveToLibrary() async {
    final result = _result;
    if (result == null) return;
    if (!AssetLibrary.instance.configured) {
      await AssetLibrary.instance.load();
    }
    if (!AssetLibrary.instance.configured) {
      if (!mounted) return;
      setState(() => _error = '还没设置素材库目录，请先去「素材库」选一个目录');
      return;
    }
    setState(() => _busy = true);
    final base = (_sourceName ?? 'portrait').replaceAll(
        RegExp(r'\.(png|jpg|jpeg)$', caseSensitive: false), '');
    final name = '$base.png';
    final png = encodePng(result.preview);
    final ok = await AssetLibrary.instance.write(name, png);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok
          ? '已存入素材库：$name（96×80，可直接导回游戏）'
          : '存入素材库失败：${AssetLibrary.instance.lastError ?? '未知原因'}'),
    ));
  }

  int get _targetCount => _reader.entryCount;

  @override
  Widget build(BuildContext context) {
    final canImport = _result != null && _targetId != null;
    return Scaffold(
      appBar: AppBar(title: const Text('肖像编辑器')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Notice(
            icon: Icons.info_outline,
            text: '把一张外部图片转成游戏里的肖像。普通图片会被缩放到 96×80；'
                '如果是 FEBuilderGBA 导出的 128×112 素材图（含嘴型/眨眼帧），'
                '会自动识别并连帧一起写入。都会量化到 16 色。',
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _pick,
                icon: const Icon(Icons.image_outlined),
                label: Text(_source == null ? '选择图片' : '换一张'),
              ),
              const SizedBox(width: 12),
              if (_sourceName != null)
                Expanded(
                  child: Text(
                    _sourceName!,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
          if (_busy) const Padding(
            padding: EdgeInsets.only(top: 16),
            child: LinearProgressIndicator(),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _Notice(
                icon: Icons.error_outline,
                color: Colors.red.shade700,
                text: _error!,
              ),
            ),
          if (_result != null) ...[
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 8),
            Text('贴合方式', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<PortraitFit>(
              segments: const [
                ButtonSegment(
                  value: PortraitFit.contain,
                  label: Text('完整放入'),
                  icon: Icon(Icons.fit_screen_outlined),
                ),
                ButtonSegment(
                  value: PortraitFit.cover,
                  label: Text('填满裁切'),
                  icon: Icon(Icons.crop_outlined),
                ),
              ],
              selected: {_fit},
              onSelectionChanged: (s) {
                setState(() => _fit = s.first);
                _reconvert();
              },
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: _includeMapFace,
              onChanged: (v) {
                setState(() => _includeMapFace = v);
                _reconvert();
              },
              title: const Text('同时换 32×32 地图小头像'),
              subtitle: const Text('从新脸的头部裁切生成；关掉则保留原来那张小脸'),
            ),
            _FrameModeSection(
              fe6: _isFe6,
              sourceSheet: _result?.sourceSheet ?? false,
              mouthMode: _mouthMode,
              blinkMode: _blinkMode,
              effectiveMouth: _result?.mouthMode,
              effectiveBlink: _result?.blinkMode,
              onMouth: (m) {
                setState(() => _mouthMode = m);
                if (_result != null) _reconvert();
              },
              onBlink: (m) {
                setState(() => _blinkMode = m);
                if (_result != null) _reconvert();
              },
            ),
            const SizedBox(height: 16),
            if (_variants != null && _variants!.isNotEmpty) ...[
              Text('量化风格', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                _result!.sourceSheet
                    ? '这张是完整素材图（128×112，含嘴型/眨眼帧），四种风格会完全相同，直接保存即可。'
                    : '并排 4 种风格，点哪张就保存哪张的 4bpp 数据。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (!_result!.sourceSheet)
                PortraitQuantRow(
                  variants: _variants!,
                  selected: _strategy,
                  onSelected: _selectStrategy,
                  romTag: widget.edit.rom.fingerprint,
                  contentVersion: widget.edit.contentVersion,
                ),
              const SizedBox(height: 16),
            ],
            _QualityHint(result: _result!),
            const SizedBox(height: 16),
            Text('效果预览', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _PreviewCompare(
              result: _result!,
              targetId: _targetId,
              reader: _reader,
              rom: widget.edit.liveRom,
            ),
            if (_result!.mapFacePreview != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _Frame(
                    child: PortraitView(
                      tile: _result!.mapFacePreview!,
                      cacheKey: PortraitImageCache.instance
                          .keyForRom(widget.edit.liveRom, 0xFFFE, 902) +
                          _result!.previewHash,
                      width: 64,
                      height: 64,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      '32×32 地图小头像（从头部裁切）。\n'
                      '战斗中、地图上显示的就是它。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            const _Notice(
              icon: Icons.warning_amber_outlined,
              text: '只有中间这块区域会显示在对话框里——四个角是原版肖像的拼装空档，'
                  '游戏里永远不会出现。预览已按同样规则裁掉。',
            ),
            const SizedBox(height: 16),
            _TargetPicker(
              reader: _reader,
              count: _targetCount,
              value: _targetId,
              onChanged: (v) => setState(() => _targetId = v),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: canImport && !_busy ? _apply : null,
              icon: const Icon(Icons.check),
              label: Text(_targetId == null
                  ? '请选择要替换的肖像'
                  : '写入第 $_targetId 条肖像'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _saveToLibrary,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('先存入素材库（不写入 ROM）'),
            ),
            const SizedBox(height: 8),
            Text(
              '提示：写完后地图上的小头像还是旧的脸；要一起换需要用「肖像移植」'
              '把地图头像一并搬过来。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// 量化质量提示。
/// 嘴型 / 眨眼两组三档选择。
///
/// 原版把「固定帧」当成一种合法状态用：封印之剑 ID 189（伊冬，终盘那条龙）
/// 与 193/194/195 的嘴型五帧逐像素相同，烈火 5 条、圣魔 5 条同理
/// （非人类角色不说话，嘴型自然不变）。所以用户用一张静态图做非人类角色时，
/// 应该能选「固定」而不用被迫带一套假动画。
class _FrameModeSection extends StatelessWidget {
  final bool fe6;

  /// 输入是不是 128×112 完整素材图（只有它才有真实帧可带）。
  final bool sourceSheet;

  final PortraitFrameMode mouthMode;
  final PortraitFrameMode blinkMode;

  /// 转换后**实际生效**的档位；与用户所选不同时说明原因
  /// （普通静态图选「真实帧」会被内核退回固定）。
  final PortraitFrameMode? effectiveMouth;
  final PortraitFrameMode? effectiveBlink;

  final ValueChanged<PortraitFrameMode> onMouth;
  final ValueChanged<PortraitFrameMode> onBlink;

  const _FrameModeSection({
    required this.fe6,
    required this.sourceSheet,
    required this.mouthMode,
    required this.blinkMode,
    this.effectiveMouth,
    this.effectiveBlink,
    required this.onMouth,
    required this.onBlink,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('嘴型动画', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        SegmentedButton<PortraitFrameMode>(
          segments: const [
            ButtonSegment(
                value: PortraitFrameMode.real, label: Text('真实帧')),
            ButtonSegment(
                value: PortraitFrameMode.fixed, label: Text('固定')),
            ButtonSegment(
                value: PortraitFrameMode.none, label: Text('无')),
          ],
          selected: {mouthMode},
          onSelectionChanged: (s) => onMouth(s.first),
        ),
        const SizedBox(height: 4),
        Text(
          switch (mouthMode) {
            PortraitFrameMode.real => sourceSheet
                ? '用这张素材图自带的真实嘴帧，游戏里嘴会开合。'
                : '普通图片没有真实帧可取，实际会写成固定嘴型。'
                    '想带真帧请导入 128×112 的 FEBuilderGBA 素材图。',
            PortraitFrameMode.fixed => fe6
                ? '五帧填同一块画面（按这条肖像的嘴部坐标），游戏里嘴不动——'
                    '对齐原版伊冬那种做法（封印之剑没有嘴型指针，这一档就是它的「无动画」）。'
                : '六帧填同一块画面（按这条肖像的嘴部坐标），游戏里嘴不动——'
                    '对齐原版那些五帧相同的条目。',
            PortraitFrameMode.none => fe6
                ? '封印之剑做不到这一项：嘴型帧画在正脸图里，条目没有嘴型指针，'
                    '游戏一定会按坐标贴一块。写入时会退回「固定」，'
                    '否则换脸后那块还是旧角色的嘴。'
                : '嘴型指针置 0，游戏不显示任何嘴型帧。',
          },
          style: theme.textTheme.bodySmall,
        ),
        if (effectiveMouth != null && effectiveMouth != mouthMode)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '实际会写成：${_label(effectiveMouth!)}（这张图没有真实帧可取）',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        const SizedBox(height: 16),
        if (fe6)
          Text(
            '眨眼动画：封印之剑没有眨眼帧（条目里没有眼睛坐标字段），此版不支持。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          )
        else ...[
          Text('眨眼动画', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SegmentedButton<PortraitFrameMode>(
            segments: const [
              ButtonSegment(
                  value: PortraitFrameMode.real, label: Text('真实帧')),
              ButtonSegment(
                  value: PortraitFrameMode.fixed, label: Text('固定')),
            ],
            selected: {blinkMode},
            onSelectionChanged: (s) => onBlink(s.first),
          ),
          const SizedBox(height: 4),
          Text(
            blinkMode == PortraitFrameMode.real
                ? (sourceSheet
                    ? '用素材图自带的两张眼型帧，游戏里会眨眼。'
                    : '普通图片没有真实眼帧，实际会写成固定（两张眼型相同）。')
                : '两张眼型帧填成一样，游戏里不眨眼。',
            style: theme.textTheme.bodySmall,
          ),
          if (effectiveBlink != null && effectiveBlink != blinkMode)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '实际会写成：${_label(effectiveBlink!)}（这张图没有真实眼帧可取）',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ],
    );
  }

  static String _label(PortraitFrameMode m) => switch (m) {
        PortraitFrameMode.real => '真实帧',
        PortraitFrameMode.fixed => '固定',
        PortraitFrameMode.none => '无',
      };
}

class _QualityHint extends StatelessWidget {
  final PortraitImportResult result;
  const _QualityHint({required this.result});

  @override
  Widget build(BuildContext context) {
    final hard = result.hardMapped;
    final transparent = result.transparentRatio;
    final lines = <String>[
      '用色 ${result.usedColors} / 16',
    ];
    if (transparent > 0.01) {
      lines.add('透明像素 ${(transparent * 100).toStringAsFixed(0)}%');
    }
    if (hard > 0) {
      lines.add('有 $hard 个像素颜色偏差较大（原图颜色超过 16 种，'
          '量化必然有损失，可试试降低原图色彩或用色块分明的图）');
    }
    if (transparent <= 0.01) {
      lines.add('图片没有透明区域：整张脸会带一块背景，建议先把背景抠成透明');
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(l, style: Theme.of(context).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}

/// 左：导入后的脸；右：目标条目原来的脸。
class _PreviewCompare extends StatelessWidget {
  final PortraitImportResult result;
  final int? targetId;
  final PortraitReader reader;
  final FeRom rom;

  const _PreviewCompare({
    required this.result,
    required this.targetId,
    required this.reader,
    required this.rom,
  });

  @override
  Widget build(BuildContext context) {
    final old = targetId == null ? null : reader.faceImage(targetId!);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: [
              _Frame(
                child: PortraitView(
                  tile: result.preview,
                  // key 必须随图变化：固定 key 会让 PortraitView 命中上一张图的缓存，
                  // 用户看到的就是「换了图但预览不变」。用像素数据的 hash 做指纹。
                  cacheKey: PortraitImageCache.instance
                      .keyForRom(rom, 0xFFFF, 900) +
                      result.previewHash,
                  width: 192,
                  height: 160,
                ),
              ),
              const SizedBox(height: 4),
              const Text('导入后', style: TextStyle(fontSize: 12)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              _Frame(
                child: old == null
                    ? const SizedBox(
                        width: 192,
                        height: 160,
                        child: Center(
                            child: Text('（这条没有图）',
                                style: TextStyle(fontSize: 12))),
                      )
                    : PortraitView(
                        tile: old,
                        cacheKey: PortraitImageCache.instance
                            .keyForRom(rom, targetId!, 901),
                        width: 192,
                        height: 160,
                      ),
              ),
              const SizedBox(height: 4),
              Text('原第 ${targetId ?? '-'} 条',
                  style: const TextStyle(fontSize: 12)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Frame extends StatelessWidget {
  final Widget child;
  const _Frame({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        // 棋盘格能同时看出透明与深色像素
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

/// 目标肖像选择：序号 + 名字 + 是否在用。
class _TargetPicker extends StatelessWidget {
  final PortraitReader reader;
  final int count;
  final int? value;
  final ValueChanged<int?> onChanged;

  const _TargetPicker({
    required this.reader,
    required this.count,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
      return const _Notice(
        icon: Icons.error_outline,
        text: '这个 ROM 的肖像表定位不到，无法导入。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('要替换哪一条肖像', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(
          value: value != null && value! < count ? value : null,
          isExpanded: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (var i = 0; i < count; i++)
              DropdownMenuItem(
                value: i,
                child: Text(
                  _label(i),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      ],
    );
  }

  String _label(int id) {
    final name = reader.nameFor(id).trim();
    final usage = reader.usageOf(id).trim();
    final has = reader.hasImage(id);
    final parts = <String>['#$id'];
    if (name.isNotEmpty) parts.add(name);
    if (usage.isNotEmpty && usage != name) parts.add('← $usage');
    if (!has) parts.add('（无图）');
    return parts.join('  ');
  }
}

class _Notice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color? color;

  const _Notice({required this.icon, required this.text, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12, color: c)),
        ),
      ],
    );
  }
}
