package com.cube.cuberemote

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * CubeRemote 자동 업데이트용 PackageInstaller intent 핸들러.
 * Dart 측 [UpdateService] 가 APK 다운로드 후 MethodChannel("com.cube.cuberemote/install")
 * 로 path 전달 → 시스템 설치 다이얼로그 표시 (사용자 confirm 1회 필수).
 */
object CubeRemoteInstaller {
    private const val CHANNEL = "com.cube.cuberemote/install"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> {
                        val path = call.argument<String>("path") ?: ""
                        if (path.isEmpty() || !File(path).exists()) {
                            result.error("NOT_FOUND", "APK not found: $path", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(activity, path)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("INSTALL_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(activity: Activity, path: String) {
        val file = File(path)
        val authority = "${activity.packageName}.fileProvider"
        val uri: Uri = FileProvider.getUriForFile(activity, authority, file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        activity.startActivity(intent)
    }
}
