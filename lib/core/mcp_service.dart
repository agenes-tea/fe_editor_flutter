import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'app_log.dart';
import 'mcp_server.dart';
import 'rom_workspace.dart';

/// MCP 服务的开关与桥接。
///
/// 传输层在原生（独立线程监听 `127.0.0.1`），这里只负责：
/// - 起停服务、报告端口
/// - 收原生转来的 JSON-RPC 请求体，交给 [McpServer] 处理，再把结果回过去
///
/// **工具清单由 Dart 提供**（`McpServer.toolDefinitions`），原生不维护副本，
/// 避免两边不一致导致「列出来了却调不动」。
class McpService {
  McpService._();

  static final McpService instance = McpService._();

  static const MethodChannel _files = MethodChannel('fe_editor/files');
  static const BasicMessageChannel<String> _channel =
      BasicMessageChannel<String>('fe_editor/mcp', StringCodec());

  bool _installed = false;
  int _port = 0;
  String? _lastError;

  /// 最近一次启动失败的原因（设置页直接展示，不必去翻日志）。
  String? get lastError => _lastError;

  /// 是否允许局域网访问（默认关）。
  ///
  /// 关的时候只绑 `127.0.0.1`：只有本机能连，别人碰不到，所以不强制口令。
  /// 开了就绑 `0.0.0.0`——同一 Wi-Fi 下任何人都能连上来改 ROM，
  /// 所以**必须**带口令（[token]）。
  bool allowLan = false;

  /// 访问口令。局域网模式下请求必须带它（`Authorization: Bearer xxx`
  /// 或 `?token=xxx`），否则服务端直接回 401。
  String token = '';

  /// 生成一个随机口令（小写字母 + 数字，16 位，够用且好念）。
  static String newToken() {
    const chars = 'abcdefghijkmnpqrstuvwxyz23456789';
    final rnd = Random.secure();
    return List.generate(16, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// 当前可用的连接地址列表。
  ///
  /// 局域网模式下把本机的每个非回环 IPv4 都列出来——手机换 Wi-Fi 后 IP 会变，
  /// 让用户从列表里挑当前那个，比自己去系统设置里翻要省事。
  Future<List<String>> addresses() async {
    if (!running) return const [];
    if (!allowLan) return ['http://127.0.0.1:$_port'];
    final out = <String>[];
    try {
      for (final ni in await NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false)) {
        for (final a in ni.addresses) {
          out.add('http://${a.address}:$_port');
        }
      }
    } catch (e) {
      AppLog.instance.log('warn', '读取局域网地址失败: $e');
    }
    if (out.isEmpty) out.add('http://127.0.0.1:$_port');
    return out;
  }

  /// 当前监听端口；未启动为 0。
  int get port => _port;

  bool get running => _port > 0;

  /// 装请求处理与工作区绑定。`main()` 里调用一次。
  ///
  /// 必须在 App 启动时就装好：服务可能在 App 退到后台后才被调用，
  /// 那时再注册处理函数就晚了。
  void install(RomWorkspace workspace) {
    McpServer.instance.attach(workspace);
    if (_installed) return;
    _installed = true;
    _channel.setMessageHandler((message) async {
      // 返回空串表示「本条无需回复」（例如通知），原生侧会转成 204 语义
      if (message == null) return '';
      try {
        return await McpServer.instance.handleBody(message) ?? '';
      } catch (e) {
        AppLog.instance.log('error', 'MCP 处理失败: $e');
        return '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"内部错误"}}';
      }
    });
  }

  /// 启动服务，返回端口；失败返回 0。
  Future<int> start({
    int preferredPort = 8422,
    bool? allowLan,
    String? token,
  }) async {
    _lastError = null;
    if (allowLan != null) this.allowLan = allowLan;
    if (token != null) this.token = token;
    if (this.allowLan && this.token.isEmpty) {
      this.token = newToken();
    }
    try {
      final p = await _files.invokeMethod<int>('mcpStart', {
        'port': preferredPort,
        'allowLan': this.allowLan,
        'token': this.token,
      });
      _port = p ?? 0;
      if (_port > 0) {
        AppLog.instance.log('info', 'MCP 服务已启动：http://127.0.0.1:$_port');
      }
      return _port;
    } catch (e) {
      AppLog.instance.log('error', 'MCP 启动失败: $e');
      _lastError = _describe(e);
      _port = 0;
      return 0;
    }
  }

  /// 把平台异常翻译成用户能照着做的说明。
  static String _describe(Object e) {
    final text = e.toString();
    if (text.contains('EPERM') || text.contains('SecurityException')) {
      return '缺少网络权限（INTERNET）。这是安装包的清单没声明该权限，'
          '请更新到修复后的版本。';
    }
    if (text.contains('EADDRINUSE') || text.contains('端口')) {
      return '端口被占用，换一个端口或先关掉占用它的程序。';
    }
    if (text.contains('引擎尚未就绪')) {
      return '界面还没初始化完成，稍后再试。';
    }
    return text;
  }

  /// 把字节写到 App 私有导出目录（`filesDir/exports`），返回绝对路径。
  ///
  /// MCP 调用不能弹系统「另存为」对话框，所以走这条通道落盘；
  /// 用户可以在系统文件管理器里从 App 私有目录取走。
  Future<String?> writeExport(String name, Uint8List bytes) async {
    try {
      return await _files.invokeMethod<String>(
          'writeExport', {'name': name, 'bytes': bytes});
    } catch (e) {
      AppLog.instance.log('error', 'MCP 导出失败: $e');
      return null;
    }
  }

  Future<void> stop() async {
    try {
      await _files.invokeMethod<bool>('mcpStop');
    } catch (e) {
      AppLog.instance.log('error', 'MCP 停止失败: $e');
    }
    _port = 0;
    AppLog.instance.log('info', 'MCP 服务已停止');
  }
}
