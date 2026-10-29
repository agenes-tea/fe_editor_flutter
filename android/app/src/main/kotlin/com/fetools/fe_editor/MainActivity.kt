package com.fetools.fe_editor

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
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
                            contentResolver.openOutputStream(uri, "wt")?.use { out ->
                                out.write(bytes)
                            } ?: throw IllegalStateException("无法写入所选文件")
                            result.success(uri.toString())
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
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) return c.getString(idx)
        }
        return uri.lastPathSegment
    }

    companion object {
        private const val REQ_PICK = 4201
        private const val REQ_SAVE = 4202
    }
}
