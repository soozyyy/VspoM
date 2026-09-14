package com.soozyyy.vspomusic.vspo_music

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.view.Gravity
import android.view.WindowManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.app.NotificationCompat

/**
 * Hosts a YouTube WebView inside an invisible (1x1) system overlay window,
 * added directly via WindowManager rather than inside any Activity's view
 * hierarchy.
 *
 * Why this survives backgrounding when the earlier in-Activity WebView did
 * not: logs from that experiment showed Android tearing down the video's
 * SurfaceView (and with it, the hardware video decoder + audio track) the
 * instant the hosting Activity's window became non-visible
 * (dispatchAppVisibility visible:false -> surfaceDestroyed -> MediaCodec
 * release -> AudioTrack.stop()). That teardown is tied to the ACTIVITY's
 * window lifecycle, not to whether audio is "supposed" to keep playing.
 *
 * A window added here via WindowManager.addView with
 * TYPE_APPLICATION_OVERLAY is a separate top-level system window, entirely
 * independent of MainActivity's window. Backgrounding, closing, or losing
 * focus on the main Activity has no effect on this window's lifecycle — it
 * keeps running (and rendering, even if invisible at 1x1) until this
 * service explicitly removes it. That's the same mechanism real background
 * YouTube-audio apps use.
 *
 * This requires the user to have granted "Draw over other apps"
 * (SYSTEM_ALERT_WINDOW) in system Settings — Android does not allow this to
 * be granted at install time.
 */
class OverlayService : Service() {

    companion object {
        const val ACTION_PLAY = "com.soozyyy.vspomusic.vspo_music.action.PLAY"
        const val ACTION_STOP = "com.soozyyy.vspomusic.vspo_music.action.STOP"
        const val EXTRA_VIDEO_ID = "videoId"
        private const val NOTIFICATION_CHANNEL_ID = "vspo_music_overlay"
        private const val NOTIFICATION_ID = 1001

        // Simple singleton reference so MainActivity's MethodChannel handler
        // can drive playback controls (pause/resume/seek/position) directly
        // on the running instance. There's only ever one instance of this
        // service in this single-user app, so this is simpler than binding.
        var instance: OverlayService? = null
    }

    private var windowManager: WindowManager? = null
    private var webView: WebView? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                removeOverlay()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }

            ACTION_PLAY -> {
                val videoId = intent.getStringExtra(EXTRA_VIDEO_ID)
                if (videoId != null) {
                    startForeground(NOTIFICATION_ID, buildNotification())
                    showOverlay(videoId)
                }
            }
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "VSpo Music playback",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
        // The mini-player's own UI intentionally has no full-stop button
        // (pause/resume covers that use case), but there still needs to be
        // some hard way to kill the overlay + foreground service entirely
        // (e.g. before uninstalling, or if something gets stuck) without
        // force-closing the app. A Stop action on the persistent notification
        // — the same pattern real media-player notifications use — covers
        // that without adding anything to the in-app mini-player.
        val stopIntent = Intent(this, OverlayService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            0,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Reusing ic_bg_service_small — already confirmed to be a valid,
        // non-adaptive notification icon (this is what fixed the earlier
        // CannotPostForegroundServiceNotificationException crash).
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("VSpo Music")
            .setContentText("Playing in the background")
            .setSmallIcon(R.drawable.ic_bg_service_small)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopPendingIntent)
            .build()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun showOverlay(videoId: String) {
        if (webView != null) {
            loadVideo(videoId)
            return
        }

        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager

        val newWebView = WebView(this)
        newWebView.settings.javaScriptEnabled = true
        newWebView.settings.mediaPlaybackRequiresUserGesture = false
        newWebView.settings.domStorageEnabled = true
        // YouTube's own player starts autoplay muted (with a "Tap to unmute"
        // prompt) as standard cross-browser autoplay-compliance behavior —
        // this is independent of mediaPlaybackRequiresUserGesture, which
        // only controls the WebView engine's own gesture requirement. Since
        // this overlay is untouchable (FLAG_NOT_TOUCHABLE) there is no way
        // to tap that prompt, so we unmute the underlying <video> element
        // directly via injected JS instead. Polling because the video
        // element may not exist yet when the page first finishes loading
        // (YouTube is a heavy SPA) or may get replaced when playback starts.
        //
        // window.__vspoUserPaused tracks whether the user explicitly paused
        // via pause()/resume() below. Without checking it here, this loop
        // would forcibly call .play() every 500ms for the first ~15s of
        // every song regardless of what the user just did — which is exactly
        // what made the pause button look broken (it would silently resume
        // itself a moment later).
        newWebView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView, url: String?) {
                super.onPageFinished(view, url)
                view.evaluateJavascript(
                    """
                    (function() {
                      window.__vspoUserPaused = false;
                      var attempts = 0;
                      var unmute = setInterval(function() {
                        attempts++;
                        var v = document.querySelector('video');
                        if (v) {
                          v.muted = false;
                          v.volume = 1;
                          if (!window.__vspoUserPaused) {
                            v.play().catch(function(e) {
                              console.log('play() rejected: ' + e);
                            });
                          }
                        }
                        if (attempts > 30) clearInterval(unmute);
                      }, 500);
                    })();
                    """.trimIndent(),
                    null
                )
            }
        }
        webView = newWebView

        val overlayType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }

        val params = WindowManager.LayoutParams(
            1,
            1,
            overlayType,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        params.x = 0
        params.y = 0

        windowManager?.addView(newWebView, params)
        loadVideo(videoId)
    }

    private fun loadVideo(videoId: String) {
        webView?.loadUrl("https://www.youtube.com/watch?v=$videoId&autoplay=1")
    }

    /**
     * Pauses the underlying <video> element directly (play/pause toggle).
     * Also flips window.__vspoUserPaused so the autoplay/unmute-forcing loop
     * in showOverlay() stops calling .play() on top of this — otherwise a
     * pause within the first ~15s of a song would get silently overridden.
     */
    fun pause() {
        webView?.evaluateJavascript(
            "(function(){window.__vspoUserPaused = true; var v=document.querySelector('video'); if(v) v.pause();})();",
            null
        )
    }

    /** Resumes the underlying <video> element directly (play/pause toggle). */
    fun resume() {
        webView?.evaluateJavascript(
            "(function(){window.__vspoUserPaused = false; var v=document.querySelector('video'); if(v) v.play();})();",
            null
        )
    }

    /** Seeks the underlying <video> element to the given position, in seconds. */
    fun seekTo(seconds: Double) {
        webView?.evaluateJavascript(
            "(function(){var v=document.querySelector('video'); if(v) v.currentTime=$seconds;})();",
            null
        )
    }

    /**
     * Reads current playback position/duration/paused state from the
     * underlying <video> element and hands it back via [callback]
     * (position seconds, duration seconds, paused). Used to drive the
     * draggable progress bar in the mini-player.
     */
    fun getPosition(callback: (Double, Double, Boolean) -> Unit) {
        val view = webView
        if (view == null) {
            callback(0.0, 0.0, true)
            return
        }
        view.evaluateJavascript(
            """
            (function() {
              var v = document.querySelector('video');
              return JSON.stringify({
                cur: v ? v.currentTime : 0,
                dur: (v && v.duration && !isNaN(v.duration)) ? v.duration : 0,
                paused: v ? v.paused : true
              });
            })();
            """.trimIndent()
        ) { rawResult ->
            try {
                // evaluateJavascript hands back the JS return value re-encoded
                // as a JSON string literal (quoted + escaped), since our script
                // returns a string. Decode that outer layer first, then parse
                // the actual JSON object it contains.
                val inner = org.json.JSONTokener(rawResult).nextValue() as String
                val json = org.json.JSONObject(inner)
                callback(
                    json.optDouble("cur", 0.0),
                    json.optDouble("dur", 0.0),
                    json.optBoolean("paused", true)
                )
            } catch (e: Exception) {
                callback(0.0, 0.0, true)
            }
        }
    }

    private fun removeOverlay() {
        webView?.let { view ->
            try {
                windowManager?.removeView(view)
            } catch (e: IllegalArgumentException) {
                // View was already detached — safe to ignore.
            }
            view.destroy()
        }
        webView = null
    }

    override fun onDestroy() {
        instance = null
        removeOverlay()
        super.onDestroy()
    }
}
