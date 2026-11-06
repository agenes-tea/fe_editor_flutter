import 'package:flutter/material.dart';

import '../core/portrait_import.dart';
import 'portrait_page.dart' show PortraitImageCache, PortraitView;

/// 并排可点选的量化风格预览行。
///
/// 同一张图用 4 种 [PortraitQuantStrategy] 各量化一份，横排展示，用户点哪张
/// 就保存哪张的 4bpp 数据。抽成独立组件，便于直接测试（不依赖选图/解码管线）。
class PortraitQuantRow extends StatelessWidget {
  final List<PortraitQuantVariant> variants;
  final PortraitQuantStrategy selected;
  final ValueChanged<PortraitQuantStrategy> onSelected;

  /// ROM 指纹 + 内容版本号：两者一起决定预览图的缓存 key。
  final int romTag;
  final int contentVersion;

  const PortraitQuantRow({
    super.key,
    required this.variants,
    required this.selected,
    required this.onSelected,
    required this.romTag,
    required this.contentVersion,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: variants.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final v = variants[i];
          return _QuantTile(
            variant: v,
            selected: v.strategy == selected,
            onTap: () => onSelected(v.strategy),
            romTag: romTag,
            contentVersion: contentVersion,
          );
        },
      ),
    );
  }
}

/// 一张量化风格预览：图（96×80）+ 风格标签；选中时高亮描边 + 对勾。
class _QuantTile extends StatelessWidget {
  final PortraitQuantVariant variant;
  final bool selected;
  final VoidCallback? onTap;

  /// ROM 指纹 + 内容版本号：两者一起决定预览图的缓存 key。
  final int romTag;
  final int contentVersion;

  const _QuantTile({
    required this.variant,
    required this.selected,
    required this.onTap,
    required this.romTag,
    required this.contentVersion,
  });

  @override
  Widget build(BuildContext context) {
    final tile = variant.result.preview;
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 132,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 120,
              height: 100,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                border: Border.all(
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.dividerColor,
                  width: selected ? 2.5 : 1,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: PortraitView(
                tile: tile,
                cacheKey: PortraitImageCache.instance
                        .keyFor(romTag, 0xFFFE, 905,
                            contentVersion: contentVersion) +
                    variant.result.previewHash,
                width: 120,
                height: 100,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected)
                  Icon(Icons.check_circle,
                      size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 3),
                Text(variant.strategy.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.normal,
                    )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
