package com.soozyyy.vspomusic.vspo_music

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "vspo_music/overlay"

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
