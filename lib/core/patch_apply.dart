import 'dart:typed_data';

import 'patch_format.dart';

/// 应用用户自带 IPS/UPS 补丁的结果。
class PatchApplyResult {
  /// 识别出的格式：`IPS` / `UPS` / `unknown`。
  final String kind;

  /// 应用成功时的新 ROM 字节；失败时为 null。
  final Uint8List? newRom;

  final String message;

  /// 与源 ROM 不同的字节数（成功时）。
  final int changedBytes;

  PatchApplyResult({
    required this.kind,
    required this.message,
    this.newRom,
    this.changedBytes = 0,
  });

  bool get ok => newRom != null;
}

/// 识别补丁格式并算出「打补丁后的 ROM」。
///
/// [source] 必须是**该补丁对应的原版 ROM**（补丁都是对某个原版生成的；
/// 会话里有未保存改动时不要在这上面打——改动的字节会被补丁内容覆盖）。
/// 拿「补丁目标侧」的 ROM 去套（反向）会被拒绝，不静默反打。
///
/// 结果长度与源不同（IPS RLE 撑长、UPS 目标变长）时拒绝：改 ROM 大小
/// 超出本工具边界。
PatchApplyResult applyPatch(Uint8List patch, Uint8List source) {
  if (patch.length < 8) {
    return PatchApplyResult(
        kind: 'unknown', message: '文件太小（< 8 字节），不是 IPS/UPS 补丁');
  }

  // "UPS1" = 55 50 53 31
  final isUps =
      patch[0] == 0x55 && patch[1] == 0x50 && patch[2] == 0x53 && patch[3] == 0x31;
  // "PATCH" = 50 41 54 43 48
  final isIps = patch[0] == 0x50 &&
      patch[1] == 0x41 &&
      patch[2] == 0x54 &&
      patch[3] == 0x43 &&
      patch[4] == 0x48;

  Uint8List? out;
  String kind;
  if (isUps) {
    out = UpsPatch.apply(patch, source);
    kind = 'UPS';
    if (out == null) {
      return PatchApplyResult(
          kind: kind,
          message: 'UPS 校验失败：源 ROM 的 CRC 与补丁记录不符'
              '（补丁可能不是为这份 ROM 生成的，或文件损坏）');
    }
  } else if (isIps) {
    out = IpsPatch.apply(patch, source);
    kind = 'IPS';
    if (out == null) {
      return PatchApplyResult(
          kind: kind, message: 'IPS 格式损坏：记录越界或 EOF 缺失');
    }
  } else {
    return PatchApplyResult(
        kind: 'unknown',
        message: '文件头不是 PATCH/UPS1，无法识别为 IPS 或 UPS 补丁');
  }

  if (out.length != source.length) {
    return PatchApplyResult(
        kind: kind,
        message: '补丁会把 ROM 从 ${(source.length ~/ 1048576)}MB 改成 '
            '${(out.length ~/ 1048576)}MB，改 ROM 大小不支持');
  }

  var changed = 0;
  for (var i = 0; i < out.length; i++) {
    if (out[i] != source[i]) changed++;
  }
  return PatchApplyResult(
    kind: kind,
    newRom: Uint8List.fromList(out),
    changedBytes: changed,
    message: '$kind 补丁应用成功，$changed 字节将改动',
  );
}
