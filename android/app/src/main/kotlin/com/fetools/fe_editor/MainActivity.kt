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
                if (resultCode != Activity.RESULT_OK || uri == null || name == null) {
                    result.success(null)
                    return
                }
                try {
                    val src = File(cacheDir, name)
                    contentResolver.openOutputStream(uri)?.use { out ->
                        src.inputStream().use { it.copyTo(out) }
                    }
                    result.success(uri.toString())
                } catch (e: Exception) {
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
