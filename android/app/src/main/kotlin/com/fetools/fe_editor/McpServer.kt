package com.fetools.fe_editor

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.StringCodec
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * App 内嵌的 MCP 服务器。
 *
 * 设计要点（都是踩过的坑换来的）：
 * - 监听跑在**独立原生线程**，不用 Dart 事件循环：App 退到后台被系统冻结时，
 *   Dart isolate 可能不跑，但原生线程仍在，客户端工具列表照样可用。
 * - `initialize` / `ping` / `tools/list` 由原生直接回，不碰 Dart；
 *   只有 `tools/call` 通过 BasicMessageChannel 桥回 Dart 执行（要读 ROM 数据）。
 * - 地址必须显式用 `127.0.0.1`，**不能用 `InetAddress.getLoopbackAddress()`**：
 *   优先 IPv6 的系统会返回 `::1`，只监听 `[::1]`，IPv4 客户端连不上。
 * - 工具清单只在 Dart 一处定义，`tools/list` 也转给 Dart 拿，避免两边不一致。
 */
class McpServer(
    private val activity: MainActivity,
    messenger: io.flutter.plugin.common.BinaryMessenger,
) {

    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val pool = Executors.newCachedThreadPool()
    private val main = Handler(Looper.getMainLooper())

    /** 与 Dart 侧的桥：请求体 JSON → 响应体 JSON。 */
    private val channel: BasicMessageChannel<String> =
        BasicMessageChannel(messenger, CHANNEL, StringCodec.INSTANCE)

    @Volatile
    var port: Int = 0
        private set

    val running: Boolean get() = serverSocket != null

    /** 鉴权 token；为空表示不校验（仅本机绑定时默认如此）。 */
    @Volatile
    var token: String = ""
        private set

    /**
     * 起服务；返回实际端口。已在跑就返回现有端口。
     *
     * [allowLan] 为 true 时绑 `0.0.0.0`（局域网可连，**必须**配 token）；
     * 否则只绑 `127.0.0.1`（只有本机能连，别人碰不到）。
     */
    fun start(
        preferredPort: Int = 8422,
        allowLan: Boolean = false,
        authToken: String = "",
    ): Int {
        synchronized(this) {
            if (serverSocket != null) return port
            token = if (allowLan) authToken else ""
            val host = if (allowLan) "0.0.0.0" else "127.0.0.1"
            val ss = try {
                // 必须开 SO_REUSEADDR：close() 之后监听端口会留在 TIME_WAIT，
                // 立刻重新开关就会报「端口被占用」。加上这一句才能反复开关。
                val sock = ServerSocket()
                sock.reuseAddress = true
                sock.bind(java.net.InetSocketAddress(InetAddress.getByName(host), preferredPort), 16)
                sock
            } catch (e: java.net.BindException) {
                throw IllegalStateException(
                    "端口 $preferredPort 已被占用，请在别的 App 里关掉占用端口的服务后重试", e
                )
            } catch (e: SecurityException) {
                throw IllegalStateException(
                    "缺少网络权限（INTERNET），无法在本机开监听端口", e
                )
            }
            port = ss.localPort
            acceptThread = Thread({
                while (!ss.isClosed) {
                    val client = try {
                        ss.accept()
                    } catch (e: IOException) {
                        break
                    }
                    pool.execute { handleClient(client) }
                }
            }, "fe-mcp-accept").apply { isDaemon = true; start() }
            return port
        }
    }

    fun stop() {
        synchronized(this) {
            try {
                serverSocket?.close()
            } catch (_: IOException) {
            }
            // 等监听线程真正退出，确保端口已经释放；
            // 否则紧接着再 start() 可能仍撞上「端口被占用」。
            acceptThread?.let { t ->
                try {
                    t.join(1000)
                } catch (_: InterruptedException) {
                }
            }
            serverSocket = null
            acceptThread = null
            port = 0
        }
    }

    private fun handleClient(client: Socket) {
        client.use { socket ->
            try {
                socket.soTimeout = SOCKET_TIMEOUT_MS
                val req = readRequest(socket.getInputStream()) ?: return
                if (!authorized(req)) {
                    writeStatus(socket, 401, "unauthorized")
                    return
                }
                val response = dispatch(req.body)
                when {
                    response == null -> writeEmptyResponse(socket, 202)
                    response.isEmpty() -> writeEmptyResponse(socket, 202)
                    else -> writeResponse(socket, response)
                }
            } catch (_: Exception) {
                // 单个客户端出错不影响服务
            }
        }
    }

    /** 一次 HTTP 请求：请求体 + 用来做 token 校验的头部与路径。 */
    private data class HttpReq(val body: String, val path: String, val headers: String)

    /**
     * token 校验。
     *
     * 只在绑 `0.0.0.0`（局域网可连）时启用 —— 那时同一 Wi-Fi 下的任何人都能连上来
     * 改 ROM，所以必须挡。只绑 127.0.0.1 时别人碰不到，不强制。
     *
     * token 可以放 `Authorization: Bearer xxx` 头，也可以放 `?token=xxx`，
     * 后者是给不支持自定义头的客户端留的口子。
     */
    private fun authorized(req: HttpReq): Boolean {
        val expected = token
        if (expected.isEmpty()) return true
        val lower = req.headers.lowercase()
        if (lower.contains("authorization: bearer ${expected.lowercase()}")) return true
        return req.path.contains("token=$expected")
    }

    /** 读 HTTP 请求体（只支持 Content-Length 定长的 POST）。 */
    private fun readRequest(input: InputStream): HttpReq? {
        val buf = BufferedInputStream(input)
        val header = StringBuilder()
        while (true) {
            val b = buf.read()
            if (b < 0) return null
            header.append(b.toChar())
            if (header.endsWith("\r\n\r\n")) break
            if (header.length > 16 * 1024) return null
        }
        val lines = header.toString().split("\r\n")
        if (lines.isEmpty()) return null
        val requestLine = lines[0].split(" ")
        if (requestLine.size < 2) return null
        val method = requestLine[0].uppercase()
        val path = requestLine[1]

        var length = 0
        for (i in 1 until lines.size) {
            val l = lines[i]
            val idx = l.indexOf(':')
            if (idx <= 0) continue
            if (l.substring(0, idx).trim().equals("Content-Length", true)) {
                length = l.substring(idx + 1).trim().toIntOrNull() ?: 0
            }
        }

        val headerText = header.toString()
        // 健康检查：GET / 或 GET /health 直接回状态，不必走 JSON-RPC
        if (method == "GET" && (path == "/" || path.startsWith("/health"))) {
            return HttpReq("""{"__health":true}""", path, headerText)
        }
        if (length <= 0) return null
        val body = ByteArrayOutputStream(length)
        val temp = ByteArray(8192)
        var remaining = length
        while (remaining > 0) {
            val n = buf.read(temp, 0, minOf(temp.size, remaining))
            if (n <= 0) break
            body.write(temp, 0, n)
            remaining -= n
        }
        return HttpReq(body.toString("UTF-8"), path, headerText)
    }

    private fun writeStatus(socket: Socket, status: Int, message: String) {
        val bytes = """{"error":"$message"}""".toByteArray(Charsets.UTF_8)
        val out = socket.getOutputStream()
        val reason = if (status == 401) "Unauthorized" else "Error"
        val head = "HTTP/1.1 $status $reason\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n"
        out.write(head.toByteArray(Charsets.US_ASCII))
        out.write(bytes)
        out.flush()
    }

    private fun writeResponse(socket: Socket, body: String) {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val out = socket.getOutputStream()
        val head = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json; charset=utf-8\r\n" +
                "Content-Length: ${bytes.size}\r\n" +
                "Connection: close\r\n\r\n"
        out.write(head.toByteArray(Charsets.US_ASCII))
        out.write(bytes)
        out.flush()
    }

    /** 通知类请求没有响应体，回 202 让客户端知道「已收下、无需等待」。 */
    private fun writeEmptyResponse(socket: Socket, status: Int) {
        val out = socket.getOutputStream()
        val head = "HTTP/1.1 $status Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        out.write(head.toByteArray(Charsets.US_ASCII))
        out.flush()
    }

    /** 健康检查由原生直接回；其余全部转给 Dart。 */
    private fun dispatch(request: String): String? {
        if (request.contains("\"__health\"")) {
            val info = """{"status":"ok","port":$port,"running":$running}"""
            return """{"jsonrpc":"2.0","id":null,"result":$info}"""
        }
        val latch = java.util.concurrent.CountDownLatch(1)
        val result = java.util.concurrent.atomic.AtomicReference<String?>(null)
        main.post {
            channel.send(request) { reply ->
                // 正常返回在这里拿到；**不能只处理 null**，否则每个请求都会
                // 白等到超时才回「执行超时」（踩过：客户端报 90022ms）。
                result.set(reply ?: ERROR_NO_REPLY)
                latch.countDown()
            }
        }
        val finished = latch.await(BRIDGE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        if (!finished) {
            return """{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"执行超时"}}"""
        }
        // 空串表示「本条无需回复」（通知类），让上层回 202 语义
        val out = result.get()
        if (out != null && out.isEmpty()) return ""
        return out
    }

    companion object {
        private const val CHANNEL = "fe_editor/mcp"
        private const val SOCKET_TIMEOUT_MS = 120_000
        private const val BRIDGE_TIMEOUT_MS = 90_000L
        private const val ERROR_NO_REPLY =
            "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"Dart 侧无响应\"}}"
    }
}
