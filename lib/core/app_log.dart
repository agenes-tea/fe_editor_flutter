import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'file_picker_service.dart';

/// 一条日志。
class LogEntry {
  final DateTime time;
  final String level;
  final String message;

  LogEntry(this.time, this.level, this.message);

  String line() {
    String two(int v) => v < 10 ? '0$v' : '$v';
    final t = time;
    return '${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:'
        '${two(t.second)} [${level.toUpperCase()}] $message';
  }
}

/// 应用内日志：内存队列 + 设备端文件（`filesDir/logs/fe_editor.log`）。
///
/// 用途：出问题时用户在「日志」页一键复制全部发给开发排查。
/// 文件在应用私有目录，不需要任何权限；测试环境没有原生通道，
/// 自动降级为纯内存日志。
class AppLog {
  AppLog._();
  static final AppLog instance = AppLog._();

  static const int _memoryLimit = 400;
  static const int _maxFileBytes = 512 * 1024;

  final Queue<LogEntry> _entries = Queue();

  File? _file;
  IOSink? _sink;
  int _fileBytes = 0;
  bool _attachPending = false;

  /// 日志文件是否已挂上（测试环境恒为 false，只有内存日志）。
  bool get hasFile => _sink != null;

  String? get filePath => _file?.path;

  /// 当前日志的只读快照（按时间正序）。
  List<LogEntry> snapshot() => _entries.toList(growable: false);

  /// 全部日志的纯文本（供「复制全部」）。
  String allText() {
    final sb = StringBuffer();
    for (final e in _entries) {
      sb.writeln(e.line());
    }
    return sb.toString();
  }

  /// 安装未捕获异常钩子：框架/UI 与平台层的崩溃都会进日志。
  ///
  /// 必须在 `runApp` 之前调用。release 下吞掉异常防止直接闪退，
  /// debug 保留默认行为（红字报错）。
  void install({required String version}) {
    log('info', 'app 启动 v$version');
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log('error', 'FlutterError: ${details.exceptionAsString()}');
      if (kReleaseMode) return;
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    PlatformDispatcher.instance.onError = (e, stack) {
      log('error', '未捕获异常: $e\n$stack');
      return true;
    };
  }

  void log(String level, String message) {
    final entry = LogEntry(DateTime.now(), level, message);
    _entries.addLast(entry);
    while (_entries.length > _memoryLimit) {
      _entries.removeFirst();
    }
    _appendFile(entry);
  }

  /// 挂接设备端日志文件（原生侧提供目录，[getLogDir] 返回 null 则静默降级）。
  Future<void> attachFile() async {
    if (_sink != null || _attachPending) return;
    _attachPending = true;
    try {
      final dir = await getLogDir();
      if (dir != null) await attachFileAt(dir);
    } catch (_) {
      // 测试环境等没有原生通道：保持内存日志
    } finally {
      _attachPending = false;
    }
  }

  /// 直接挂接指定目录下的日志文件（测试 / 桌面用）。可重复调用，会先关闭旧文件。
  Future<void> attachFileAt(String dir) async {
    await _sink?.close();
    _sink = null;
    final d = Directory(dir);
    if (!d.existsSync()) await d.create(recursive: true);
    final f = File('${d.path}/fe_editor.log');
    _file = f;
    _sink = f.openWrite(mode: FileMode.append);
    _fileBytes = 0;
    for (final e in _entries) {
      final b = utf8.encode('${e.line()}\n');
      _sink!.add(b);
      _fileBytes += b.length;
    }
    if (_fileBytes > _maxFileBytes) await _rotate();
  }

  /// 把缓冲的文件写入刷到磁盘（测试 / 退出前用）。
  Future<void> flush() async {
    final sink = _sink;
    if (sink == null) return;
    await sink.flush();
  }

  void _appendFile(LogEntry entry) {
    final sink = _sink;
    if (sink == null) return;
    final b = utf8.encode('${entry.line()}\n');
    sink.add(b);
    _fileBytes += b.length;
  }

  /// 文件超过上限：只保留后半，开头写截断标记。
  Future<void> _rotate() async {
    final keep = _entries.toList(growable: true);
    final kept = keep.sublist(keep.length ~/ 2);
    _entries.clear();
    _entries.addLast(LogEntry(DateTime.now(), 'warn', '日志超出上限，较早条目已截断'));
    _entries.addAll(kept);
    try {
      await _sink?.close();
      _sink = null;
      final f = _file;
      if (f != null) {
        _fileBytes = 0;
        _sink = f.openWrite(mode: FileMode.write);
        for (final e in _entries) {
          final b = utf8.encode('${e.line()}\n');
          _sink!.add(b);
          _fileBytes += b.length;
        }
      }
    } catch (_) {
      // 文件写失败不影响内存日志
    }
  }

  /// 清空日志（内存与文件都清，留下「日志已清空」标记）。
  Future<void> clear() async {
    _entries.clear();
    _entries.addLast(LogEntry(DateTime.now(), 'info', '日志已清空'));
    if (_sink == null) return;
    try {
      await _sink!.close();
      _sink = null;
      final f = _file;
      if (f != null) {
        _fileBytes = 0;
        _sink = f.openWrite(mode: FileMode.write);
        for (final e in _entries) {
          final b = utf8.encode('${e.line()}\n');
          _sink!.add(b);
          _fileBytes += b.length;
        }
      }
    } catch (_) {}
  }
}
