import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fe_editor/core/portrait_import.dart';
import 'package:fe_editor/ui/portrait_quant_row.dart';

/// 一张高分多色图（量化策略才有可分辨差异）。
Uint8List _rich(int w, int h) {
  final d = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      final t = (x + y) / (w + h);
      d[o] = (t * 255 * 2).toInt().clamp(0, 255);
      d[o + 1] = (90 + t * 120).toInt().clamp(0, 255);
      d[o + 2] = (200 - t * 150).toInt().clamp(0, 255);
      d[o + 3] = 255;
    }
  }
  return d;
}

void main() {
  testWidgets('PortraitQuantRow：并排 4 张可点选，点选切换选中项', (tester) async {
    final variants =
        PortraitImporter.convertAll(_rich(384, 320), 384, 320, fe6: true);
    expect(variants.length, 4);
    var selected = variants.first.strategy;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: PortraitQuantRow(
              variants: variants,
              selected: selected,
              onSelected: (s) => selected = s,
              romTag: 1,
              contentVersion: 0,
            ),
          ),
        ),
      ),
    );

    // 4 种风格标签都在
    expect(find.text('原版质感'), findsOneWidget);
    expect(find.text('细腻渐变'), findsOneWidget);
    expect(find.text('明亮色彩'), findsOneWidget);
    expect(find.text('自然'), findsOneWidget);
    // 默认选 1 张 → 恰好 1 个对勾
    expect(find.byIcon(Icons.check_circle), findsOneWidget);

    // 点「明亮色彩」→ 选中项变成 bright，仍只有 1 个对勾
    await tester.tap(find.text('明亮色彩'));
    await tester.pump();
    expect(selected, PortraitQuantStrategy.bright);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 再点「自然」→ 切回 natural
    await tester.tap(find.text('自然'));
    await tester.pump();
    expect(selected, PortraitQuantStrategy.natural);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
