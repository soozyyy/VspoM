package com.soozyyy.vspomusic.vspo_music

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "vspo_music/overlay"
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 4201

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasOverlayPermission" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        Settings.canDrawOverlays(this)
                    } else {
                        true
                    }
                    result.success(granted)
                }

                "requestOverlayPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !Settings.canDrawOverlays(this)) {
                        // This has to be a manual grant in system Settings — Android does
                        // not allow SYSTEM_ALERT_WINDOW to be granted at install time or
                        // via a normal runtime permission dialog, precisely because it's a
                        // powerful "draw over other apps" capability.
                        val intent = Intent(
                            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                            Uri.parse("package:$packageName")
                        )
                        startActivity(intent)
                    }
                    result.success(null)
                }

                // Starting with Android 13 (API 33), POST_NOTIFICATIONS is a
                // runtime permission — declaring it in the manifest alone is
                // not enough. Without this being granted, startForeground()
                // in OverlayService still succeeds and audio still plays, but
                // the system silently shows no notification at all, which
                // means no visible Stop action either. This is exactly what
                // was happening: the overlay itself was fine, but there was
                // no notification to see or stop it from.
                "hasNotificationPermission" -> {
                    val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.POST_NOTIFICATIONS
                        ) == PackageManager.PERMISSION_GRANTED
                    } else {
                        true
                    }
                    result.success(granted)
                }

                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            NOTIFICATION_PERMISSION_REQUEST_CODE
                        )
                    }
                    result.success(null)
                }

                "playVideo" -> {
                    val videoId = call.argument<String>("videoId")
                    val serviceIntent = Intent(this, OverlayService::class.java).apply {
                        action = OverlayService.ACTION_PLAY
                        putExtra(OverlayService.EXTRA_VIDEO_ID, videoId)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(serviceIntent)
                    } else {
                        startService(serviceIntent)
                    }
                    result.success(null)
                }

                "stop" -> {
                    val serviceIntent = Intent(this, OverlayService::class.java).apply {
                        action = OverlayService.ACTION_STOP
                    }
                    startService(serviceIntent)
                    result.success(null)
                }

                "pause" -> {
                    OverlayService.instance?.pause()
                    result.success(null)
                }

                "resume" -> {
                    OverlayService.instance?.resume()
                    result.success(null)
                }

                "seek" -> {
                    val seconds = call.argument<Double>("seconds") ?: 0.0
                    OverlayService.instance?.seekTo(seconds)
                    result.success(null)
                }

                "getPosition" -> {
                    val service = OverlayService.instance
                    if (service == null) {
                        result.success(mapOf("position" to 0.0, "duration" to 0.0, "paused" to true))
                    } else {
                        service.getPosition { position, duration, paused ->
                            result.success(
                                mapOf("position" to position, "duration" to duration, "paused" to paused)
                            )
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}
