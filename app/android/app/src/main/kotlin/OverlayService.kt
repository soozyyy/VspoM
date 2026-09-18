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
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
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
        const val EXTRA_TITLE = "title"
        const val EXTRA_ARTIST = "artist"
        private const val NOTIFICATION_CHANNEL_ID = "vspo_music_overlay"
        private const val NOTIFICATION_ID = 1001

        // Simple singleton reference so MainActivity's MethodChannel handler
        // can drive playback controls (pause/resume/seek/position) directly
        // on the running instance. There's only ever one instance of this
        // service in this single-user app, so this is simpler than binding.
        var instance: OverlayService? = null

        // Delays (ms, relative to each loadUrl() call) at which the setup
        // script is re-pushed into the page from the Kotlin side, on top of
        // the normal onPageStarted/onPageFinished injections. See the long
        // comment in loadVideo() for why this exists — short version: we
        // caught a real silent-song occurrence where NONE of our injected
        // script's own log lines ever appeared for that video, meaning the
        // page's "finished loading" event that we relied on to inject
        // simply never fired (or fired far too late), so nothing ever
        // unmuted that video. The script is idempotent (guarded by
        // window.__vspoInitialized) so re-pushing it on a schedule like
        // this is always safe and just acts as a safety net.
        private val REINJECT_DELAYS_MS = longArrayOf(400, 900, 1800, 3200, 5000, 8000)
    }

    private var windowManager: WindowManager? = null
    private var webView: WebView? = null
    private val mainHandler = Handler(Looper.getMainLooper())

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
                // Falls back to the old generic text if Dart didn't send them
                // (shouldn't happen, but keeps the notification sane either way).
                val title = intent.getStringExtra(EXTRA_TITLE) ?: "VSpo Music"
                val artist = intent.getStringExtra(EXTRA_ARTIST) ?: "Playing in the background"
                if (videoId != null) {
                    startForeground(NOTIFICATION_ID, buildNotification(title, artist))
                    showOverlay(videoId)
                }
            }
        }
        return START_STICKY
    }

    private fun buildNotification(title: String, artist: String): Notification {
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
            .setContentTitle(title)
            .setContentText(artist)
            .setSmallIcon(R.drawable.ic_bg_service_small)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopPendingIntent)
            .build()
    }

    /**
     * The whole unmute-enforcement / audio-graph / diagnostic script,
     * injected into the page repeatedly (see loadVideo()) rather than
     * exactly once. It self-guards with window.__vspoInitialized so
     * re-injecting it is always a safe no-op once it has already set up —
     * that's what makes it safe to fire from several different triggers
     * (onPageStarted, onPageFinished, and a handful of scheduled Kotlin-side
     * pokes) without risk of double-initializing or double-attaching the
     * Web Audio graph to the same <video> element.
     */
    private fun injectionScript(): String {
        return """
        (function() {
          if (window.__vspoInitialized) { return; }
          window.__vspoInitialized = true;
          window.__vspoUserPaused = false;
          window.__vspoHookedVideo = null;
          window.__vspoWasAd = false;
          var tickCount = 0;

          // Everything logs through here (tagged so it's easy to grep in
          // Logcat).
          function log(msg) { console.log('[vspo] ' + msg); }
          log('page loaded: ' + location.href);

          function setupAudioGraph(v) {
            // Belt-and-suspenders guard directly on the element itself, on
            // top of the window.__vspoHookedVideo check at the call site —
            // createMediaElementSource() can only ever be called ONCE for
            // a given underlying media element/resource; calling it twice
            // throws InvalidStateError and leaves that video's audio graph
            // broken for the rest of the song. This was actually observed
            // happening (twice in a row) in a captured log, almost
            // certainly caused by the old single-shot injection running
            // again and resetting window.__vspoHookedVideo to null while
            // the previous run's interval was still alive and already
            // hooked to the same element.
            if (v.__vspoAudioSetup) {
              log('setupAudioGraph skipped, element already set up');
              return;
            }
            v.__vspoAudioSetup = true;
            try {
              if (!window.__vspoAudioCtx) {
                window.__vspoAudioCtx = new (window.AudioContext || window.webkitAudioContext)();
                log('created AudioContext, initial state=' + window.__vspoAudioCtx.state);
              }
              var ctx = window.__vspoAudioCtx;
              if (ctx.state === 'suspended') {
                ctx.resume().then(function() {
                  log('AudioContext resume() succeeded, state=' + ctx.state);
                }).catch(function(e) {
                  log('AudioContext resume() FAILED: ' + e);
                });
              }
              var source = ctx.createMediaElementSource(v);
              var compressor = ctx.createDynamicsCompressor();
              compressor.threshold.value = -24;
              compressor.knee.value = 30;
              compressor.ratio.value = 12;
              // A very fast attack (the old 3ms) reacts within a single
              // wave cycle on bass-heavy transients (kicks, bass hits),
              // which is a known way for a dynamics processor to introduce
              // its own audible distortion/artifacts rather than just
              // smoothing loudness. A slower attack still catches sustained
              // loud passages fine, just without chasing every short
              // transient — this is the more likely fix for the split-
              // second "stutter"/glitch, since that's exactly the kind of
              // artifact a too-fast compressor attack produces.
              compressor.attack.value = 0.02;
              compressor.release.value = 0.3;
              var gainNode = ctx.createGain();
              gainNode.gain.value = 1.0;

              // Safety limiter, AFTER the boost gain and BEFORE the
              // speakers. Without this, boosting a quiet song by several
              // times its original level could push its louder moments
              // past full scale (amplitude > 1.0) — Web Audio doesn't clamp
              // that gracefully, it just hard-clips the waveform flat,
              // which is exactly the harsh "broken speaker" / white-noise
              // crackle that showed up on some boosted songs. This is a
              // second DynamicsCompressorNode tuned as a brick-wall
              // limiter (very low threshold, high ratio, near-instant
              // attack) so anything the gain stage pushes too high gets
              // caught and smoothly capped instead of clipping.
              var limiter = ctx.createDynamicsCompressor();
              limiter.threshold.value = -1;
              limiter.knee.value = 0;
              limiter.ratio.value = 20;
              // 1ms was likely too fast here too — sub-2ms attack times on
              // a dynamics node are a well-known source of audible
              // artifacts on their own (it can start clamping mid wave-
              // cycle on bass frequencies). 3ms is still fast enough to
              // catch the boost stage overshooting before it clips, just
              // without being fast enough to distort on its own.
              limiter.attack.value = 0.003;
              limiter.release.value = 0.15;

              // Smaller FFT size than before (1024 vs 2048) — halves the
              // amount of data pulled off the audio thread and summed on
              // the main thread every 300ms tick. Simpler/cheaper per-tick
              // work for the same RMS estimate; not perceptibly less
              // accurate for a loudness reading like this.
              var analyser = ctx.createAnalyser();
              analyser.fftSize = 1024;

              source.connect(compressor);
              compressor.connect(gainNode);
              gainNode.connect(limiter);
              limiter.connect(ctx.destination);
              // Measure from BEFORE the boost gain (straight off the
              // within-song compressor), since that's the "how loud is
              // this song really" reading we want the leveler to react to
              // — measuring after the limiter would make loud songs look
              // artificially level and confuse the boost decision.
              compressor.connect(analyser);

              // Boost-only loudness leveling. Requested explicitly: quiet
              // uploads should get raised toward a target level, but
              // already-adequate/loud uploads should NOT get turned down
              // (gain floor is 1.0x, never less). The gain is decided
              // mostly ONCE from a short initial sampling window right at
              // the start of the song, then only ever creeps upward slowly
              // afterward if needed — this is what stops the audible
              // "pumping" the old version had, since that recalculated and
              // re-applied a new gain value every single 300ms tick for the
              // whole song. The limiter above is what now keeps this boost
              // from ever audibly clipping, even at the top of its range.
              var data = new Float32Array(analyser.fftSize);
              var targetRms = 0.13;
              var maxGain = 3.0;
              var gain = 1.0;
              var sampleSum = 0, sampleCount = 0;
              var initialized = false;
              setInterval(function() {
                if (v.paused || v.ended) return;
                analyser.getFloatTimeDomainData(data);
                var sum = 0;
                for (var i = 0; i < data.length; i++) sum += data[i] * data[i];
                var rms = Math.sqrt(sum / data.length);
                if (rms < 0.002) return; // near-silence (intro/outro) - don't let it skew the reading
                if (!initialized) {
                  sampleSum += rms;
                  sampleCount++;
                  if (sampleCount >= 5) {
                    var avgRms = sampleSum / sampleCount;
                    gain = Math.max(1.0, Math.min(maxGain, targetRms / avgRms));
                    gainNode.gain.setTargetAtTime(gain, ctx.currentTime, 0.8);
                    initialized = true;
                    log('initial gain set to ' + gain.toFixed(2) + ' (avgRms=' + avgRms.toFixed(4) + ')');
                  }
                  return;
                }
                // Occasional gentle upward-only correction afterward (e.g. a
                // song that starts loud then goes quiet later) - this can
                // never reduce gain below what's already set, so it can't
                // reintroduce audible pumping.
                var suggested = Math.max(1.0, Math.min(maxGain, targetRms / rms));
                if (suggested > gain + 0.05) {
                  gain += (suggested - gain) * 0.02;
                  gainNode.gain.setTargetAtTime(gain, ctx.currentTime, 1.5);
                }
              }, 300);
              log('audio graph attached to this video element');
            } catch (e) {
              log('audio graph setup FAILED: ' + e);
            }
          }

          setInterval(function() {
            tickCount++;
            var v = document.querySelector('video');

            // Diagnostic-only signal, not used to gate any actual logic.
            // The previous selector (.ad-showing / .ytp-ad-player-overlay)
            // turned out to be a near-permanent false positive on this
            // page's mobile layout (logged as true almost immediately for
            // nearly every song, ad or not). Checking whether the ad
            // container actually has content in it is a much more honest
            // signal of a real ad actually showing.
            var adsContainer = document.querySelector('.video-ads, .ytp-ad-module');
            var isAd = !!(adsContainer && adsContainer.children && adsContainer.children.length > 0);
            if (isAd !== window.__vspoWasAd) {
              log((isAd ? 'AD STARTED' : 'AD ENDED') +
                  ' at t=' + (v ? v.currentTime.toFixed(1) : 'n/a'));
              window.__vspoWasAd = isAd;
            }

            if (v && v !== window.__vspoHookedVideo) {
              log('NEW video element (first load or swap), src=' + (v.currentSrc || v.src || '?'));
              window.__vspoHookedVideo = v;
              setupAudioGraph(v);
            } else if (window.__vspoAudioCtx && window.__vspoAudioCtx.state === 'suspended') {
              // Retry every tick, not just once at setup — if this ever
              // gets stuck suspended, that alone would cause total silence
              // with everything else (video position, muted/paused flags)
              // looking completely normal.
              log('AudioContext still suspended, retrying resume()');
              window.__vspoAudioCtx.resume().catch(function(e) {});
            }

            if (v) {
              var wasMuted = v.muted;
              var wasQuiet = v.volume < 0.99;
              v.muted = false;
              v.volume = 1;
              if (wasMuted || wasQuiet) {
                log('re-forced unmute (was muted=' + wasMuted + ', volume=' + v.volume + ')');
              }
              if (!window.__vspoUserPaused && v.paused) {
                log('video unexpectedly paused, calling play()');
                v.play().catch(function(e) { log('play() rejected: ' + e); });
              }
              // Full status line every ~4s so a whole song's log stays
              // readable, plus every state change above logs immediately
              // regardless of this throttle.
              if (tickCount % 8 === 0) {
                var ctxState = window.__vspoAudioCtx ? window.__vspoAudioCtx.state : 'none';
                log('status t=' + v.currentTime.toFixed(1) + '/' + (v.duration || 0).toFixed(1) +
                    ' paused=' + v.paused + ' muted=' + v.muted + ' vol=' + v.volume +
                    ' audioCtx=' + ctxState + ' isAd=' + isAd);
              }
            } else if (tickCount % 8 === 0) {
              log('status: no <video> element found on page');
            }

            var skipBtn = document.querySelector(
              '.ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button'
            );
            if (skipBtn) {
              log('clicking skip-ad button');
              try { skipBtn.click(); } catch (e) {}
            }
          }, 500);
        })();
        """.trimIndent()
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

        // Without a WebChromeClient, WebView console.log() calls go nowhere —
        // they are silently discarded, not just hidden. This is why none of
        // the debug logging below would ever have shown up before. Forwards
        // every console message to Logcat under tag "VspoOverlayJS" so it can
        // be captured with `adb logcat -s VspoOverlayJS:D` (or an on-device
        // log-viewer app, for catching it during a drive away from a PC).
        newWebView.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(consoleMessage: ConsoleMessage): Boolean {
                Log.d(
                    "VspoOverlayJS",
                    "${consoleMessage.message()} [${consoleMessage.sourceId()}:${consoleMessage.lineNumber()}]"
                )
                return true
            }
        }

        // YouTube's own player starts autoplay muted (with a "Tap to unmute"
        // prompt) as standard cross-browser autoplay-compliance behavior —
        // this is independent of mediaPlaybackRequiresUserGesture, which
        // only controls the WebView engine's own gesture requirement. Since
        // this overlay is untouchable (FLAG_NOT_TOUCHABLE) there is no way
        // to tap that prompt, so we unmute the underlying <video> element
        // directly via injected JS instead (see injectionScript() above).
        //
        // Inject as early as possible (onPageStarted) in addition to
        // onPageFinished — a real silent-song occurrence was captured where
        // NO log line from this script ever appeared for that video at all
        // (not even "page loaded"), while network-level console warnings
        // for that same page load did appear. That means onPageFinished
        // itself either never fired or fired far too late — WebView only
        // calls it once ALL sub-resources finish loading, and YouTube can
        // already be autoplaying (muted, per browser default) well before
        // that "load" event completes. If some slow/stuck resource (ads,
        // analytics beacons, etc.) delays or blocks that event, the whole
        // song can play out muted with our unmute/audio-graph script never
        // injected at all — while position/duration polling still looks
        // completely normal, since getPosition() is a totally separate,
        // on-demand JS query that doesn't depend on this script running.
        // The script is idempotent (window.__vspoInitialized guard), so
        // firing it from multiple places, plus the scheduled Kotlin-side
        // re-injection in loadVideo() below, is always safe.
        newWebView.webViewClient = object : WebViewClient() {
            override fun onPageStarted(view: WebView, url: String?, favicon: android.graphics.Bitmap?) {
                super.onPageStarted(view, url, favicon)
                view.evaluateJavascript(injectionScript(), null)
            }

            override fun onPageFinished(view: WebView, url: String?) {
                super.onPageFinished(view, url)
                view.evaluateJavascript(injectionScript(), null)
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

        // Safety net on top of onPageStarted/onPageFinished: schedule a
        // handful of additional pokes that just re-push the same (idempotent)
        // script on a schedule, regardless of whether either WebViewClient
        // callback ever fires for this navigation. See the long comment
        // above showOverlay()'s WebViewClient for why this exists — this is
        // specifically to survive a page load that never reaches "finished"
        // in a reasonable time (or at all), which is the leading theory for
        // the freshest captured silent-song occurrence.
        for (delayMs in REINJECT_DELAYS_MS) {
            mainHandler.postDelayed({
                // If the service/overlay was torn down (song changed again,
                // or playback stopped) before this fires, webView may now be
                // pointed at a different video or be null - evaluateJavascript
                // against the current webView is still safe either way since
                // the script only ever acts on window.__vspoInitialized /
                // whatever <video> is currently on the page.
                webView?.evaluateJavascript(injectionScript(), null)
            }, delayMs)
        }
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
        mainHandler.removeCallbacksAndMessages(null)
        removeOverlay()
        super.onDestroy()
    }
}