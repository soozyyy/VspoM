package com.soozyyy.vspomusic.vspo_music

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import java.io.File
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "vspo_music/overlay"
    // Native -> Dart, the opposite direction to CHANNEL above. Needed because
    // Skip/Previous can't be answered natively: OverlayService only knows how
    // to play a given video ID, while the shuffle order and current position
    // within it live entirely in Dart (_playOrder / _playOrderIndex in
    // main.dart). So a hardware or lock-screen skip is a round trip —
    // session callback -> here -> Dart's _next()/_previous() -> playVideo.
    private val EVENTS_CHANNEL = "vspo_music/overlay_events"
    private val NOTIFICATION_PERMISSION_REQUEST_CODE = 4201

    companion object {
        /**
         * Where OverlayService posts skip events. Set while Dart is listening,
         * null otherwise.
         *
         * Null is a real, reachable state, not just defensive nulling: this
         * sink belongs to the FlutterEngine, which FlutterActivity tears down
         * when the Activity is destroyed — i.e. when the app is swiped out of
         * recents. Audio keeps playing (the overlay window and the foreground
         * service are independent of the Activity, which is the whole point of
         * OverlayService), and play/pause keeps working because it is handled
         * natively, but skip/previous quietly stop working until the app is
         * reopened. Fixing that means caching the FlutterEngine so it outlives
         * the Activity — deliberately not done, see claude/next-features-plan.md.
         */
        var events: EventChannel.EventSink? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }

                override fun onCancel(arguments: Any?) {
                    events = null
                }
            })

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
                    val title = call.argument<String>("title")
                    val artist = call.argument<String>("artist")
                    // Null for a song whose catalog entry predates the
                    // loudness scrape. NaN is the "unknown" marker the
                    // service reads back, and the injected script treats
                    // that as gain 1.0 (leave the level alone).
                    val loudnessDb = call.argument<Double>("loudnessDb")
                    val serviceIntent = Intent(this, OverlayService::class.java).apply {
                        action = OverlayService.ACTION_PLAY
                        putExtra(OverlayService.EXTRA_VIDEO_ID, videoId)
                        putExtra(OverlayService.EXTRA_TITLE, title)
                        putExtra(OverlayService.EXTRA_ARTIST, artist)
                        putExtra(OverlayService.EXTRA_LOUDNESS_DB, loudnessDb ?: Double.NaN)
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

                // In-app updates (see _checkForUpdate in main.dart). CI sets
                // versionCode to the workflow run number and versionName to
                // 1.0.<run number>, matching what it writes to version.json.
                "getAppVersion" -> {
                    val info = packageManager.getPackageInfo(packageName, 0)
                    result.success(
                        mapOf(
                            "build" to PackageInfoCompat.getLongVersionCode(info),
                            "version" to (info.versionName ?: "")
                        )
                    )
                }

                // Where Dart should download the update APK. Must sit under
                // cache/updates/, the folder res/xml/update_paths.xml shares.
                "updateApkPath" -> {
                    val dir = File(cacheDir, "updates").apply { mkdirs() }
                    result.success(File(dir, "update.apk").absolutePath)
                }

                // Opens Android's own "Do you want to update this app?"
                // screen. If installing from VspoM isn't allowed yet, the
                // installer itself asks for that first, then continues.
                // Installing over the existing app (same signing key) keeps
                // every permission already granted.
                "installApk" -> {
                    val file = File(call.argument<String>("path")!!)
                    val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
                    val intent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/vnd.android.package-archive")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }
}
