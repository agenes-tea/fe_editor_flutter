import 'package:flutter/material.dart';

import '../core/rom_session.dart';

/// 已打开 ROM 的横向切换栏。
///
/// 跨版本移植需要在源/目标两个 ROM 之间来回看，所以同时打开多个 ROM 时
/// 顶部列出每一个：点一下切过去，长按关闭。只有一个会话时由调用方决定不显示。
class RomSessionBar extends StatelessWidget {
  final List<RomSession> sessions;
  final int? activeId;
  final ValueChanged<RomSession> onSelect;
  final ValueChanged<RomSession> onClose;

  const RomSessionBar({
    super.key,
    required this.sessions,
    required this.activeId,
    required this.onSelect,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 66,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: sessions.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final s = sessions[i];
          final active = s.id == activeId;
          return InkWell(
            onTap: () => onSelect(s),
            onLongPress: () => onClose(s),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 200,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: active
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: active ? scheme.primary : Colors.transparent,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      Icon(Icons.memory, size: 14, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(s.versionId,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                      if (s.rom.hasChanges) ...[
                        const SizedBox(width: 6),
                        Text('已改 ${s.rom.changedByteCount}B',
                            style: TextStyle(fontSize: 10, color: scheme.error)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    s.fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
