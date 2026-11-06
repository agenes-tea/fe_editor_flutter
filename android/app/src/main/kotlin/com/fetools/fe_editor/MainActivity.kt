package com.fetools.fe_editor

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private val channel = "fe_editor/files"
    private var pendingResult: MethodChannel.Result? = null
    private var pendingSaveName: String? = null

    /// 上一次用「打开 ROM」选中的文档 URI。
    /// 覆盖模式要用它直接写回原文件，所以这里保留并申请持久读授权。
    private var sourceUri: Uri? = null

    /// 外部工作区目录（用户选过一次后持久记在 settings 里）。
    /// 有了它，Dart 侧就不必每次手动选 ROM。
    private var workspaceUri: Uri? = null

    /// 素材库目录（肖像/战斗动画/图标等导出的 PNG 放这里）。
    /// 与工作区分开：工作区只装 ROM，素材不想跟 ROM 混在一个授权里。
    private var assetDirUri: Uri? = null

    /// 供 MCP 桥接用（McpServer 拿不到 flutterEngine 这个 protected 成员）。
    private var mcpMessenger: io.flutter.plugin.common.BinaryMessenger? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        mcpMessenger = flutterEngine.dartExecutor.binaryMessenger
        // 恢复上次选定的工作区目录：重启后不必再选一次
        workspaceUri = readWorkspaceUri()
        assetDirUri = readAssetDirUri()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickWorkspaceDir" -> {
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            // 工作区要能列出、读取、写回里面的 ROM
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(intent, REQ_PICK_DIR)
                    }
                    "workspaceDir" -> {
                        try {
                            result.success(describeWorkspace())
                        } catch (e: Exception) {
                            // 启动时读目录失败不能拖垮 App：当作未设置
                            result.success(null)
                        }
                    }
                    "clearWorkspaceDir" -> {
                        val old = workspaceUri
                        workspaceUri = null
                        writeWorkspaceUri(null)
                        if (old != null) {
                            try {
                                contentResolver.releasePersistableUriPermission(
                                    old,
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                )
                            } catch (_: Exception) {
                                // 提供方不支持持久授权回收，忽略
                            }
                        }
                        result.success(true)
                    }
                    "listWorkspaceRoms" -> {
                        try {
                            result.success(listWorkspaceRoms())
                        } catch (e: Exception) {
                            result.error("LIST_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "readWorkspaceRom" -> {
                        val name = call.argument<String>("name")
                        if (name == null || name.isEmpty()) {
                            result.error("BAD_ARGS", "缺少文件名", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // 从工作区打开的 ROM 也要能被「覆盖模式」写回：
                            // 否则用户改完点导出，永远报「没有可覆盖的源文件」。
                            // 工作区目录是持久授权的，所以直接记下具体文件的 URI 即可。
                            findRomByName(name)?.let { uri ->
                                sourceUri = uri
                                try {
                                    contentResolver.takePersistableUriPermission(
                                        uri,
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                    )
                                } catch (_: SecurityException) {
                                    // 树授权通常已含子文件权限，失败不影响写回
                                }
                            }
                            result.success(readWorkspaceRom(name))
                        } catch (e: Exception) {
                            result.error("READ_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "writeWorkspaceRom" -> {
                        val name = call.argument<String>("name")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (name == null || bytes == null) {
                            result.error("BAD_ARGS", "缺少文件名或内容", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(writeWorkspaceRom(name, bytes))
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "pickAssetDir" -> {
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(intent, REQ_PICK_ASSET_DIR)
                    }
                    "assetDir" -> {
                        try {
                            result.success(describeAssetDir())
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }
                    "clearAssetDir" -> {
                        val old = assetDirUri
                        assetDirUri = null
                        writeAssetDirUri(null)
                        if (old != null) {
                            try {
                                contentResolver.releasePersistableUriPermission(
                                    old,
                                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                                )
                            } catch (_: Exception) {
                                // 提供方不支持回收，忽略
                            }
                        }
                        result.success(true)
                    }
                    "listAssets" -> {
                        try {
                            result.success(listAssets())
                        } catch (e: Exception) {
                            result.error("LIST_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "readAsset" -> {
                        val name = call.argument<String>("name")
                        if (name == null || name.isEmpty()) {
                            result.error("BAD_ARGS", "缺少文件名", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(readAsset(name))
                        } catch (e: Exception) {
                            result.error("READ_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "writeAsset" -> {
                        val name = call.argument<String>("name")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (name == null || bytes == null) {
                            result.error("BAD_ARGS", "缺少文件名或内容", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(writeAsset(name, bytes))
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "listAssetStore" -> {
                        val dir = call.argument<String>("dir")
                        if (dir == null || dir.isEmpty()) {
                            result.error("BAD_ARGS", "缺少目录", null)
                            return@setMethodCallHandler
                        }
                        result.success(assetStoreFiles(dir))
                    }
                    "readAssetStore" -> {
                        val dir = call.argument<String>("dir")
                        val name = call.argument<String>("name")
                        if (dir == null || name == null) {
                            result.error("BAD_ARGS", "缺少目录或文件名", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(readAssetStore(dir, name))
                        } catch (e: Exception) {
                            result.error("READ_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "writeAssetStore" -> {
                        val dir = call.argument<String>("dir")
                        val name = call.argument<String>("name")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (dir == null || name == null || bytes == null) {
                            result.error("BAD_ARGS", "缺少目录、文件名或内容", null)
                            return@setMethodCallHandler
                        }
                        try {
                            result.success(writeAssetStore(dir, name, bytes))
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "deleteAssetStore" -> {
                        val dir = call.argument<String>("dir")
                        val name = call.argument<String>("name")
                        if (dir == null || name == null) {
                            result.error("BAD_ARGS", "缺少目录或文件名", null)
                            return@setMethodCallHandler
                        }
                        result.success(deleteAssetStore(dir, name))
                    }
                    "importAssetFromLibrary" -> {
                        // 素材库（SAF）里的文件 → AssetStore（App 私有目录）。
                        // **字节全程在原生侧走**：不经过 Dart、不进 AI 上下文，
                        // 所以 1MB 的图也能一步入库（这就是 handle 通道的核心收益）。
                        val name = call.argument<String>("name")
                        val dir = call.argument<String>("dir")
                        if (name == null || name.isEmpty() || dir == null || dir.isEmpty()) {
                            result.error("BAD_ARGS", "缺少素材名或目标目录", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val bytes = readAsset(name)
                            val handle = crcHandle(bytes)
                            writeAssetStore(dir, "$handle.bin", bytes)
                            result.success(
                                mapOf(
                                    "handle" to handle,
                                    "size" to bytes.size,
                                    "source_name" to name,
                                )
                            )
                        } catch (e: Exception) {
                            result.error("IMPORT_FAILED", friendlyIoError(e), null)
                        }
                    }
                    "pickRom" -> {
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "*/*"
                            // 需要长期读写授权：覆盖模式要写回同一个文件
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                        }
                        startActivityForResult(intent, REQ_PICK)
                    }
                    "saveFile" -> {
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        val name = call.argument<String>("name")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (name == null || bytes == null) {
                            result.error("BAD_ARGS", "缺少文件名或内容", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        pendingSaveName = name
                        // 先落到缓存，再用系统「另存为」让用户选位置
                        val tmp = File(cacheDir, name)
                        FileOutputStream(tmp).use { it.write(bytes) }
                        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            putExtra(Intent.EXTRA_TITLE, name)
                        }
                        startActivityForResult(intent, REQ_SAVE)
                    }
                    "overwrite" -> {
                        val bytes = call.argument<ByteArray>("bytes")
                        val uri = sourceUri
                        if (bytes == null) {
                            result.error("BAD_ARGS", "缺少内容", null)
                            return@setMethodCallHandler
                        }
                        if (uri == null) {
                            result.error("NO_SOURCE", "没有可覆盖的源文件", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // 不同 provider 支持的模式不同：文档树认 "wt"，
                            // 媒体库（content://media/...）在部分设备上只认 "rwt"。
                            // 实测「downloads 下的文件」用 "wt" 会抛 FileNotFoundException，
                            // 所以失败后换模式再试一次，都失败才真报错。
                            var lastError: Exception? = null
                            for (mode in listOf("wt", "rwt")) {
                                try {
                                    val out = contentResolver.openOutputStream(uri, mode)
                                    if (out == null) {
                                        lastError = IllegalStateException(
                                            "无法打开写入流（mode=$mode）"
                                        )
                                        continue
                                    }
                                    out.use { it.write(bytes) }
                                    result.success(uri.toString())
                                    return@setMethodCallHandler
                                } catch (e: Exception) {
                                    lastError = e
                                }
                            }
                            throw lastError ?: IllegalStateException("无法写入")
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", e.message, null)
                        }
                    }
                    "sourceName" -> result.success(sourceUri?.let { displayName(it) })
                    "readSettings" -> {
                        val f = File(filesDir, "settings")
                        result.success(if (f.exists()) f.readText() else null)
                    }
                    "writeSettings" -> {
                        val text = call.argument<String>("text") ?: ""
                        try {
                            File(filesDir, "settings").writeText(text)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", e.message, null)
                        }
                    }
                    "appLogDir" -> {
                        // 日志写在应用私有目录，不需要存储权限
                        val dir = File(filesDir, "logs")
                        dir.mkdirs()
                        result.success(dir.absolutePath)
                    }
                    "writeExport" -> {
                        // MCP 导出用：写到 App 私有导出目录，返回绝对路径。
                        // 不弹系统「另存为」——那需要前台交互，MCP 调用不能阻塞等它。
                        val name = call.argument<String>("name")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (name == null || bytes == null) {
                            result.error("BAD_ARGS", "缺少文件名或内容", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val dir = File(filesDir, "exports")
                            dir.mkdirs()
                            // 只取最后一段，避免路径穿越
                            val safe = name.substringAfterLast('/').substringAfterLast('\\')
                            val out = File(dir, safe)
                            FileOutputStream(out).use { it.write(bytes) }
                            result.success(out.absolutePath)
                        } catch (e: Exception) {
                            result.error("WRITE_FAILED", e.message, null)
                        }
                    }
                    "mcpStart" -> {
                        try {
                            val preferred = call.argument<Int>("port") ?: 8422
                            val allowLan = call.argument<Boolean>("allowLan") ?: false
                            val token = call.argument<String>("token") ?: ""
                            if (allowLan && token.isEmpty()) {
                                // 不强制局域网口令：风险由界面弹框确认。
                                // 保留这行只是为了知会日志，不阻止启动。
                            }
                            val messenger = mcpMessenger
                                ?: throw IllegalStateException("引擎尚未就绪")
                            val server = mcpInstance ?: McpServer(this, messenger).also { mcpInstance = it }
                            val actual = server.start(preferred, allowLan, token)
                            result.success(actual)
                        } catch (e: Exception) {
                            result.error("MCP_START_FAILED", e.message, null)
                        }
                    }
                    "mcpStop" -> {
                        mcpInstance?.stop()
                        result.success(true)
                    }
                    "mcpStatus" -> {
                        result.success(mapOf(
                            "running" to (mcpInstance?.running ?: false),
                            "port" to (mcpInstance?.port ?: 0),
                            "needsToken" to ((mcpInstance?.token?.isNotEmpty()) ?: false)
                        ))
                    }
                    "pickJson" -> {
                        // 配方导入：选一个 JSON 文件，直接读回文本内容。
                        // 配方很小（几 KB），不走缓存文件，也不需要持久授权。
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/json"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivityForResult(intent, REQ_PICK_JSON)
                    }
                    "pickText" -> {
                        // 对话补丁导入：选任意文本文件，直接读回文本（UTF-8）。
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "text/*"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivityForResult(intent, REQ_PICK_TEXT)
                    }
                    "pickPatch" -> {
                        // 应用补丁：选 .ips/.ups 文件，读进缓存文件，
                        // 把真实路径交给 Dart（同 pickRom，但不记 sourceUri——
                        // 补丁文件不是 ROM，不能被「覆盖回源文件」误伤）。
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/octet-stream"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivityForResult(intent, REQ_PICK_PATCH)
                    }
                    "pickImage" -> {
                        // 肖像导入：选一张 PNG/JPG，读进缓存文件后交给 Dart 解码。
                        // 与 pickPatch 同一套流程（不记 sourceUri——图片不是 ROM）。
                        if (pendingResult != null) {
                            result.error("BUSY", "已有选择框在等待", null)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "image/*"
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        startActivityForResult(intent, REQ_PICK_IMAGE)
                    }
                    "shareGbaRom" -> {
                        // 「用模拟器打开」：改后的 ROM 先落缓存，包成 content URI
                        // 分享出去，用户在分享面板里选 mGBA 等模拟器直接开。
                        val name = call.argument<String>("name")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (name == null || bytes == null) {
                            result.error("BAD_ARGS", "缺少文件名或内容", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val safe = name.substringAfterLast('/').substringAfterLast('\\')
                            val f = File(cacheDir, "share_$safe")
                            FileOutputStream(f).use { it.write(bytes) }
                            val uri = FileProvider.getUriForFile(
                                this, "$packageName.share", f)
                            // 先试专用 MIME（mGBA 等声明了 x-gba-rom 的模拟器
                            // 会直接出现在面板上），没有能接的应用再退到通用型
                            var sent = false
                            for (mime in listOf("application/x-gba-rom", "application/octet-stream")) {
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = mime
                                    putExtra(Intent.EXTRA_STREAM, uri)
                                    putExtra(Intent.EXTRA_SUBJECT, safe)
                                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                try {
                                    startActivity(Intent.createChooser(send, "选择模拟器打开"))
                                    sent = true
                                    break
                                } catch (e: ActivityNotFoundException) {
                                    // 没有应用接这种 MIME，试下一种
                                }
                            }
                            if (!sent) {
                                result.error("NO_TARGET", "没找到能接收 ROM 的应用（请先安装 mGBA 等模拟器）", null)
                            } else {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.error("SHARE_FAILED", e.message, null)
                        }
                    }
                    "openUrl" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("BAD_ARGS", "缺少 url", null)
                            return@setMethodCallHandler
                        }
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OPEN_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        mcpInstance?.stop()
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQ_PICK -> {
                val result = pendingResult ?: return
                pendingResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                sourceUri = uri
                // 让授权跨进程重启仍有效，否则下次覆盖会被系统拒绝
                try {
                    contentResolver.takePersistableUriPermission(
                        uri,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                    )
                } catch (_: SecurityException) {
                    // 某些文件提供方不支持持久授权，退化为仅本次会话可写
                }
                try {
                    result.success(copyToCache(uri))
                } catch (e: Exception) {
                    result.error("READ_FAILED", e.message, null)
                }
            }
            REQ_SAVE -> {
                val result = pendingResult ?: return
                pendingResult = null
                val name = pendingSaveName
                pendingSaveName = null
                val uri = data?.data
                val tmp = File(cacheDir, name)
                if (resultCode != Activity.RESULT_OK || uri == null || name == null) {
                    tmp.delete()
                    result.success(null)
                    return
                }
                try {
                    contentResolver.openOutputStream(uri)?.use { out ->
                        tmp.inputStream().use { it.copyTo(out) }
                    }
                    tmp.delete()
                    result.success(uri.toString())
                } catch (e: Exception) {
                    tmp.delete()
                    result.error("WRITE_FAILED", e.message, null)
                }
            }
            REQ_PICK_JSON -> {
                val result = pendingResult ?: return
                pendingResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                try {
                    val text =
                        contentResolver.openInputStream(uri)?.use { it.readBytes().decodeToString() }
                    result.success(text)
                } catch (e: Exception) {
                    result.error("READ_FAILED", e.message, null)
                }
            }
            REQ_PICK_TEXT -> {
                val result = pendingResult ?: return
                pendingResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                try {
                    val text =
                        contentResolver.openInputStream(uri)?.use { it.readBytes().decodeToString() }
                    result.success(text)
                } catch (e: Exception) {
                    result.error("READ_FAILED", e.message, null)
                }
            }
            REQ_PICK_PATCH -> {
                val result = pendingResult ?: return
                pendingResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                try {
                    result.success(copyToCache(uri))
                } catch (e: Exception) {
                    result.error("READ_FAILED", e.message, null)
                }
            }
            REQ_PICK_IMAGE -> {
                val result = pendingResult ?: return
                pendingResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                try {
                    result.success(copyToCache(uri))
                } catch (e: Exception) {
                    result.error("READ_FAILED", e.message, null)
                }
            }
            REQ_PICK_DIR -> {
                val result = pendingResult ?: return
                pendingResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                // 必须申请持久授权：否则重启 App 后目录就无权访问了，
                // 「不用每次手选 ROM」这个需求就无从谈起。
                val takeFlags = data.flags and
                        (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                try {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                } catch (e: Exception) {
                    // SecurityException、不支持持久授权（某些提供方抛
                    // IllegalArgumentException）都在这里；不能漏补，
                    // 否则主线程直接崩
                    result.error(
                        "NO_PERSIST",
                        "这个目录不支持长期授权，换一个目录（如「文档」或 SD 卡根目录）再试",
                        null
                    )
                    return
                }
                workspaceUri = uri
                writeWorkspaceUri(uri)
                // describeWorkspace 会解析目录名；任何失败都不能让主线程崩，
                // 宁可只回一个最少信息（uri）+ 通用名
                val info = try {
                    describeWorkspace()
                } catch (e: Exception) {
                    mapOf("uri" to uri.toString(), "name" to "工作区", "path" to uri.path.orEmpty())
                }
                result.success(info)
            }
            REQ_PICK_ASSET_DIR -> {
                val result = pendingResult ?: return
                pendingResult = null
                val uri = data?.data
                if (resultCode != Activity.RESULT_OK || uri == null) {
                    result.success(null)
                    return
                }
                val takeFlags = data.flags and
                        (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                try {
                    contentResolver.takePersistableUriPermission(uri, takeFlags)
                } catch (e: Exception) {
                    result.error(
                        "NO_PERSIST",
                        "这个目录不支持长期授权，换一个目录（如「文档」或 SD 卡根目录）再试",
                        null
                    )
                    return
                }
                assetDirUri = uri
                writeAssetDirUri(uri)
                val info = try {
                    describeAssetDir()
                } catch (e: Exception) {
                    mapOf("uri" to uri.toString(), "name" to "素材库", "path" to uri.path.orEmpty())
                }
                result.success(info)
            }
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    /// 系统选择器给的是 content:// Uri，读成缓存文件后把真实路径交给 Dart。
    private fun copyToCache(uri: Uri): String {
        val name = displayName(uri) ?: "rom.gba"
        val out = File(cacheDir, name)
        contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "无法打开所选文件" }
            FileOutputStream(out).use { output -> input.copyTo(output) }
        }
        return out.absolutePath
    }

    private fun displayName(uri: Uri): String? {
        // SAF 的 tree URI（目录）**不能**直接 query，会抛
        // UnsupportedOperationException: Unsupported Uri；
        // 目录名要走 DocumentsContract 那套解析（见 treeDisplayName）。
        if (isTreeUri(uri)) return treeDisplayName(uri)
        return try {
            contentResolver.query(uri, null, null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) return c.getString(idx)
            }
            uri.lastPathSegment
        } catch (e: Exception) {
            // 提供方不支持查询时退回路径末段，不要让界面崩掉
            uri.lastPathSegment
        }
    }

    private fun isTreeUri(uri: Uri): Boolean =
        uri.pathSegments.firstOrNull() == "tree"

    /**
     * 目录（tree URI）的显示名。
     *
     * `lastPathSegment` 形如 `primary:模拟器/Test`，取最后一段做目录名；
     * 不去 query（tree URI 不支持，会抛异常导致闪退）。
     */
    private fun treeDisplayName(uri: Uri): String? {
        try {
            val docId = android.provider.DocumentsContract.getTreeDocumentId(uri)
            val tail = docId.substringAfterLast('/').substringAfterLast(':')
            if (tail.isNotEmpty()) return tail
        } catch (_: Exception) {
            // 不是标准 DocumentsProvider 的 tree URI，退回下面
        }
        val seg = uri.lastPathSegment ?: return null
        return seg.substringAfterLast('/').substringAfterLast(':')
            .takeIf { it.isNotEmpty() } ?: seg
    }

    // ---------- 外部工作区 ----------

    /** 工作区目录的显示信息；未选目录或授权已失效时返回 null。 */
    private fun describeWorkspace(): Map<String, Any>? {
        val uri = workspaceUri ?: return null
        // 授权可能在系统设置里被撤销、或被清理器回收：失效就当作未设置，
        // 否则每次都抛异常、用户也不知道该重选。
        if (!hasPersistedPermission(uri)) {
            workspaceUri = null
            writeWorkspaceUri(null)
            return null
        }
        return try {
            mapOf(
                "uri" to uri.toString(),
                "name" to (displayName(uri) ?: "工作区"),
                "path" to uri.path.orEmpty()
            )
        } catch (e: Exception) {
            // 任何解析异常都不能让界面崩掉：退回一个可用但信息少的描述
            workspaceUri = null
            writeWorkspaceUri(null)
            null
        }
    }

    /** 该 URI 是否还持有持久化读写授权。 */
    private fun hasPersistedPermission(uri: Uri): Boolean {
        return try {
            contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isReadPermission
            }
        } catch (_: Exception) {
            false
        }
    }

    /**
     * 把 SAF/IO 异常翻成用户能照着做的提示。
     *
     * `SecurityException` / `Unsupported Uri` 几乎都是「授权没了」或
     * 「这个目录的提供方不支持」，原样抛出去用户只会看到一屏堆栈。
     */
    private fun friendlyIoError(e: Exception): String {
        val text = (e.message ?: e.toString())
        return when {
            e is SecurityException || text.contains("permission", true) ->
                "没有这个目录的访问权限（可能已在系统设置里撤销）。请重新选择工作区目录。"
            text.contains("Unsupported Uri", true) ->
                "这个目录不支持当前访问方式。请换一个目录（如「文档」或 SD 卡根目录下的文件夹）。"
            text.contains("ENOENT", true) || text.contains("No such file", true) ->
                "文件不存在或已被移走。"
            else -> text
        }
    }

    /**
     * 列出工作区里的 ROM 文件。
     *
     * 只按扩展名筛选：目录里往往还有补丁、截图、文本，
     * 全列出来会让用户在一堆无关文件里找 ROM。
     */
    private fun listWorkspaceRoms(): List<Map<String, Any>> {
        val root = workspaceUri ?: return emptyList()
        // 授权丢了就别去 query（会抛 SecurityException）；
        // 先清记录，下次进界面会提示重选
        if (!hasPersistedPermission(root)) {
            workspaceUri = null
            writeWorkspaceUri(null)
            return emptyList()
        }
        val docId = android.provider.DocumentsContract.getTreeDocumentId(root)
        val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
            root, docId
        )
        val out = mutableListOf<Map<String, Any>>()
        val projection = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            android.provider.DocumentsContract.Document.COLUMN_SIZE,
            android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        contentResolver.query(children, projection, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                if (!isRomFileName(name)) continue
                out.add(
                    mapOf(
                        "name" to name,
                        "docId" to c.getString(0),
                        "size" to c.getLong(2),
                        "modified" to c.getLong(3),
                    )
                )
            }
        }
        out.sortBy { it["name"] as String }
        return out
    }

    /** 读工作区里的一个 ROM，直接返回字节（不经 cacheDir，不会积累副本）。 */
    private fun readWorkspaceRom(name: String): ByteArray {
        val uri = findRomByName(name)
            ?: throw IllegalStateException("工作区里找不到「$name」")
        return contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("无法读取「$name」")
    }

    /** 把修改结果写回工作区里的同名文件（原地覆盖）。 */
    private fun writeWorkspaceRom(name: String, bytes: ByteArray): Boolean {
        val uri = findRomByName(name)
            ?: throw IllegalStateException("工作区里找不到「$name」")
        contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) }
            ?: throw IllegalStateException("无法写入「$name」")
        return true
    }

    /** 按显示名在工作区里找一个 ROM 文档。 */
    private fun findRomByName(name: String): Uri? {
        val root = workspaceUri ?: return null
        val docId = android.provider.DocumentsContract.getTreeDocumentId(root)
        val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
            root, docId
        )
        val projection = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        )
        contentResolver.query(children, projection, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                if (c.getString(1) == name) {
                    return android.provider.DocumentsContract.buildDocumentUriUsingTree(
                        root, c.getString(0)
                    )
                }
            }
        }
        return null
    }

    // ---------- 素材库 ----------

    /** 素材库目录的显示信息；未选或授权已失效时返回 null。 */
    private fun describeAssetDir(): Map<String, Any>? {
        val uri = assetDirUri ?: return null
        if (!hasPersistedPermission(uri)) {
            assetDirUri = null
            writeAssetDirUri(null)
            return null
        }
        return try {
            mapOf(
                "uri" to uri.toString(),
                "name" to (displayName(uri) ?: "素材库"),
                "path" to uri.path.orEmpty()
            )
        } catch (e: Exception) {
            assetDirUri = null
            writeAssetDirUri(null)
            null
        }
    }

    /** 列出素材库里的文件（PNG/BIN/JSON 等，按文件名排序）。 */
    private fun listAssets(): List<Map<String, Any>> {
        val root = assetDirUri ?: return emptyList()
        if (!hasPersistedPermission(root)) {
            assetDirUri = null
            writeAssetDirUri(null)
            return emptyList()
        }
        val out = mutableListOf<Map<String, Any>>()
        queryChildren(root) { name, docId, size, modified ->
            out.add(
                mapOf(
                    "name" to name,
                    "docId" to (docId ?: ""),
                    "size" to size,
                    "modified" to modified,
                )
            )
        }
        out.sortBy { it["name"] as String }
        return out
    }

    private fun readAsset(name: String): ByteArray {
        val uri = findChildByName(assetDirUri, name)
            ?: throw IllegalStateException("素材库里找不到「$name」")
        return contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: throw IllegalStateException("无法读取「$name」")
    }

    /**
     * 写一个素材到素材库。
     *
     * 同名就原地覆盖（不建副本）：导出肖像时反复调同一名字，
     * 每次都攒一份 `foo (1).png`、`foo (2).png` 反而不像素材库。
     */
    private fun writeAsset(name: String, bytes: ByteArray): Boolean {
        val root = assetDirUri ?: throw IllegalStateException("还没选素材库目录")
        if (!hasPersistedPermission(root)) {
            assetDirUri = null
            writeAssetDirUri(null)
            throw SecurityException("素材库授权已失效，请重新选择目录")
        }
        val existing = findChildByName(root, name)
        if (existing != null) {
            contentResolver.openOutputStream(existing, "wt")?.use { it.write(bytes) }
                ?: throw IllegalStateException("无法写入「$name」")
            return true
        }
        val docId = android.provider.DocumentsContract.getTreeDocumentId(root)
        val parent = android.provider.DocumentsContract.buildDocumentUriUsingTree(root, docId)
        val target = android.provider.DocumentsContract.createDocument(
            contentResolver, parent, mimeTypeOf(name), name
        ) ?: throw IllegalStateException("无法在素材库里新建「$name」")
        contentResolver.openOutputStream(target, "wt")?.use { it.write(bytes) }
            ?: throw IllegalStateException("无法写入「$name」")
        return true
    }

    // ---------- AssetStore（App 私有目录，无需存储权限） ----------

    /**
     * 解析素材仓库目录：`filesDir/<dir>`。
     *
     * `dir` 由 Dart 侧给出（形如 `assets/<项目指纹>`），这里只允许相对路径，
     * 拒绝 `..` 与绝对路径，避免被传入任意路径。
     */
    private fun resolveAssetStoreDir(dir: String): File {
        val clean = dir.trim().trimStart('/')
        if (clean.isEmpty() || clean.contains("..")) {
            throw IllegalArgumentException("非法目录：$dir")
        }
        val root = File(filesDir, "assets").canonicalFile
        val target = File(filesDir, clean).canonicalFile
        if (!target.path.startsWith(root.path + File.separator)) {
            throw IllegalArgumentException("目录越界：$dir")
        }
        target.mkdirs()
        return target
    }

    private fun assetStoreFiles(dir: String): List<String> {
        val d = resolveAssetStoreDir(dir)
        return (d.listFiles() ?: emptyArray())
            .filter { it.isFile }
            .map { it.name }
            .sorted()
    }

    private fun readAssetStore(dir: String, name: String): ByteArray? {
        val safe = name.substringAfterLast('/').substringAfterLast('\\')
        val f = File(resolveAssetStoreDir(dir), safe)
        // 不存在返回 null，不是抛异常：元数据索引 _meta.json 首次访问时必然不存在，
        // 抛异常会让「空素材库」变成一次工具调用失败。
        return if (f.exists()) f.readBytes() else null
    }

    private fun writeAssetStore(dir: String, name: String, bytes: ByteArray): Boolean {
        val safe = name.substringAfterLast('/').substringAfterLast('\\')
        val f = File(resolveAssetStoreDir(dir), safe)
        FileOutputStream(f).use { it.write(bytes) }
        return true
    }

    private fun deleteAssetStore(dir: String, name: String): Boolean {
        val safe = name.substringAfterLast('/').substringAfterLast('\\')
        val f = File(resolveAssetStoreDir(dir), safe)
        return !f.exists() || f.delete()
    }

    /**
     * 与 Dart 侧 `AssetStore.handleOf` **位对位一致**的内容哈希。
     *
     * 两边都会到同一个 handle 是必须的：原生先存好文件，Dart 侧再按 handle
     * 写元数据；算法不一致就会变成两份孤儿文件。
     */
    private fun crcHandle(bytes: ByteArray): String {
        val c = java.util.zip.CRC32().apply { update(bytes) }.value
        val head = if (bytes.size >= 16) bytes.copyOfRange(0, 8) else bytes
        val tail = if (bytes.size >= 16) bytes.copyOfRange(bytes.size - 8, bytes.size) else ByteArray(0)
        val len = bytes.size
        val sample = head + tail + byteArrayOf(
            (len and 0xFF).toByte(),
            ((len shr 8) and 0xFF).toByte(),
            ((len shr 16) and 0xFF).toByte(),
        )
        val c2 = java.util.zip.CRC32().apply { update(sample) }.value
        return java.lang.String.format("%08x%08x", c, c2)
    }

    private fun mimeTypeOf(name: String): String {
        val lower = name.lowercase()
        return when {
            lower.endsWith(".png") -> "image/png"
            lower.endsWith(".json") -> "application/json"
            lower.endsWith(".txt") -> "text/plain"
            else -> "application/octet-stream"
        }
    }

    /** 遍历某目录下的条目，回调 (显示名, docId, 大小, 最后修改)。 */
    private inline fun queryChildren(
        root: Uri,
        onRow: (String, String?, Long, Long) -> Unit
    ) {
        val docId = android.provider.DocumentsContract.getTreeDocumentId(root)
        val children = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
            root, docId
        )
        val projection = arrayOf(
            android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            android.provider.DocumentsContract.Document.COLUMN_SIZE,
            android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        contentResolver.query(children, projection, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                onRow(name, c.getString(0), c.getLong(2), c.getLong(3))
            }
        }
    }

    /** 在某目录里按显示名找子文档。 */
    private fun findChildByName(root: Uri?, name: String): Uri? {
        if (root == null) return null
        var found: Uri? = null
        queryChildren(root) { childName, docId, _, _ ->
            if (found == null && childName == name && docId != null) {
                found = android.provider.DocumentsContract.buildDocumentUriUsingTree(
                    root, docId
                )
            }
        }
        return found
    }

    private fun assetSettingsFile() = File(filesDir, "assetdir")

    private fun readAssetDirUri(): Uri? {
        return try {
            val f = assetSettingsFile()
            if (!f.exists()) return null
            val text = f.readText().trim()
            if (text.isEmpty()) null else Uri.parse(text)
        } catch (_: Exception) {
            null
        }
    }

    private fun writeAssetDirUri(uri: Uri?) {
        try {
            val f = assetSettingsFile()
            if (uri == null) f.delete() else f.writeText(uri.toString())
        } catch (_: Exception) {
            // 保存失败只影响下次是否要重选
        }
    }

    private fun isRomFileName(name: String): Boolean {
        val lower = name.lowercase()
        return lower.endsWith(".gba") || lower.endsWith(".agb") || lower.endsWith(".bin")
    }

    /** 工作区 URI 存在应用私有设置文件里（跟 Dart 侧的 settings 同一份，不同 key）。 */
    private fun workspaceSettingsFile() = File(filesDir, "workspace")

    private fun readWorkspaceUri(): Uri? {
        return try {
            val f = workspaceSettingsFile()
            if (!f.exists()) return null
            val text = f.readText().trim()
            if (text.isEmpty()) null else Uri.parse(text)
        } catch (_: Exception) {
            null
        }
    }

    private fun writeWorkspaceUri(uri: Uri?) {
        try {
            val f = workspaceSettingsFile()
            if (uri == null) f.delete() else f.writeText(uri.toString())
        } catch (_: Exception) {
            // 保存失败不影响本次会话（只是下次要重选）
        }
    }

    companion object {
        /// 进程级 MCP 单例：Activity 因配置变化重建时 `mcpInstance` 仍指向原实例，
        /// 不再 new 第二个——否则每次重建都多一个监听 socket，端口越堆越多（实测
        /// 8422/8423/8424 同时监听、健康检查 running 却为 false）。
        @Volatile private var mcpInstance: McpServer? = null

        private const val REQ_PICK = 4201
        private const val REQ_SAVE = 4202
        private const val REQ_PICK_JSON = 4203
        private const val REQ_PICK_DIR = 4204
        private const val REQ_PICK_TEXT = 4205
        private const val REQ_PICK_PATCH = 4206
        private const val REQ_PICK_ASSET_DIR = 4207
        private const val REQ_PICK_IMAGE = 4208
    }
}
