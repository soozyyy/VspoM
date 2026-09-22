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
        // YouTube's own measured integrated loudness for this video, in dB
        // relative to its -14 LUFS reference (positive = louder than
        // reference). Scraped per-song into catalog.json and carried through
        // Dart -> here -> the injected script, where it sets the playback
        // gain. Absent/NaN means "unknown", which the script treats as
        // gain 1.0 (no change).
        const val EXTRA_LOUDNESS_DB = "loudnessDb"
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

    // Loudness of the song currently being loaded. Read by injectionScript()
    // so every injection for this page (onPageStarted, onPageFinished, and
    // the scheduled re-pokes) carries the same value. Set before loadVideo()
    // navigates, so it's always in sync with whatever page is loading.
    private var currentLoudnessDb: Double? = null

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
                // NaN is the "not known" marker — a song added to the catalog
                // since the last scrape run simply won't have a value yet.
                val loudnessDb = intent.getDoubleExtra(EXTRA_LOUDNESS_DB, Double.NaN)
                    .takeIf { !it.isNaN() }
                if (videoId != null) {
                    startForeground(NOTIFICATION_ID, buildNotification(title, artist))
                    showOverlay(videoId, loudnessDb)
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
        // Interpolated into the script below as a JS number literal, or the
        // literal `null` when the catalog has no loudness for this song.
        val loudnessLiteral = currentLoudnessDb?.toString() ?: "null"
        return """
        (function() {
          if (window.__vspoInitialized) { return; }
          window.__vspoInitialized = true;
          window.__vspoUserPaused = false;
          window.__vspoHookedVideo = null;
          window.__vspoWasAd = false;
          var tickCount = 0;

          // How loud THIS song is, in dB relative to YouTube's -14 LUFS
          // reference. Baked in from Kotlin per page load; null when the
          // catalog has no value for this song yet.
          var loudnessDb = $loudnessLiteral;
          // Calibration knob: shifts the whole app's output level without
          // touching any of the logic below. 0 = match YouTube's reference.
          // Raise it if everything feels too quiet on your phone.
          var TARGET_OFFSET_DB = 0;
          // Bounds on what we'll do to any one song. Real catalog values land
          // around 0.37x (loudest) to 2.0x (quietest), so these only catch
          // garbage data.
          var MIN_GAIN = 0.25;
          var MAX_GAIN = 4.0;

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
              var gainNode = ctx.createGain();

              // Safety limiter, AFTER the gain and BEFORE the speakers.
              // Without this, boosting a quiet song could push its louder
              // moments past full scale (amplitude > 1.0) — Web Audio
              // doesn't clamp that gracefully, it just hard-clips the
              // waveform flat, which is the harsh "broken speaker" crackle
              // that showed up on some boosted songs. A DynamicsCompressor
              // tuned as a brick-wall limiter (very low threshold, high
              // ratio, fast attack) caps overshoot smoothly instead.
              //
              // This is the ONLY dynamics processing left. The old chain
              // also ran a second compressor (threshold -24, ratio 12) on
              // the way in, which squashed loud passages WITHIN a song —
              // the opposite of the goal here, which is to even out volume
              // BETWEEN songs while leaving each song's own dynamics alone.
              var limiter = ctx.createDynamicsCompressor();
              limiter.threshold.value = -1;
              limiter.knee.value = 0;
              limiter.ratio.value = 20;
              // Sub-2ms attack times on a dynamics node are a known source
              // of audible artifacts (they can start clamping mid wave-
              // cycle on bass frequencies). 3ms still catches overshoot
              // before it clips without distorting on its own.
              limiter.attack.value = 0.003;
              limiter.release.value = 0.15;

              source.connect(gainNode);
              gainNode.connect(limiter);
              limiter.connect(ctx.destination);

              // ---- loudness normalization -------------------------------
              // One gain, decided once, held for the whole song. No
              // measuring, no sampling window, no mid-song adjustment —
              // the number comes from YouTube's own analysis of the entire
              // track, which is strictly better than anything we could
              // estimate from the first second and a half of audio.
              //
              // The v.volume term is what makes this correct without us
              // having to know whether YouTube already normalized this
              // page. YouTube levels loud uploads down by setting
              // video.volume to 10^(-loudnessDb/20), and never boosts quiet
              // ones. So:
              //   - if it DID normalize, v.volume cancels the loudness term
              //     out and we land on ~1.0, adding nothing;
              //   - if it DIDN'T, v.volume is 1 and our gain does the whole
              //     correction, turning loud songs down and quiet ones up.
              // Either way the song ends up at the same target level, with
              // no risk of attenuating twice.
              //
              // This only works because the 500ms tick below no longer
              // forces v.volume back to 1 — that line destroyed YouTube's
              // per-song leveling on every track and was the single biggest
              // cause of songs not matching in volume.
              function computeGain(vol) {
                if (loudnessDb === null || !isFinite(loudnessDb)) return 1.0;
                var ytVol = (vol > 0 && vol <= 1) ? vol : 1;
                var songFactor = Math.pow(10, loudnessDb / 20);
                var g = Math.pow(10, TARGET_OFFSET_DB / 20) / (songFactor * ytVol);
                return Math.min(MAX_GAIN, Math.max(MIN_GAIN, g));
              }

              // YouTube may not have applied its own attenuation yet at the
              // moment this graph is built, so recompute if v.volume later
              // changes. Driven from the existing 500ms tick, and only on
              // an actual change — v.volume doesn't move during a song, so
              // this settles within a tick or two and then never fires
              // again. No mid-song drift.
              v.__vspoRetune = function() {
                var g = computeGain(v.volume);
                if (Math.abs(g - gainNode.gain.value) < 0.001) return;
                gainNode.gain.value = g;
                log('gain retuned to ' + g.toFixed(3) +
                    ' (ytVolume=' + v.volume.toFixed(3) + ')');
              };
              v.__vspoLastVol = v.volume;
              gainNode.gain.value = computeGain(v.volume);
              log('gain=' + gainNode.gain.value.toFixed(3) +
                  ' (loudnessDb=' + loudnessDb +
                  ', ytVolume=' + v.volume.toFixed(3) + ')');

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
              // Unmute only. We deliberately do NOT force v.volume back to
              // 1 any more: that is how YouTube applies its own per-song
              // loudness normalization, so overwriting it threw that away
              // on every track (twice a second) and left every song at its
              // raw uploaded level. Muting is different — YouTube autoplays
              // muted for browser autoplay compliance, and since this
              // overlay is untouchable there's no way to tap "unmute", so
              // this part stays.
              var wasMuted = v.muted;
              v.muted = false;
              if (wasMuted) {
                log('re-forced unmute (volume left at ' + v.volume.toFixed(3) + ')');
              }
              // Pick up YouTube's normalization if it lands after our audio
              // graph was built. Only fires on an actual change.
              if (v.__vspoRetune && v.volume !== v.__vspoLastVol) {
                v.__vspoLastVol = v.volume;
                v.__vspoRetune();
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
    private fun showOverlay(videoId: String, loudnessDb: Double?) {
        if (webView != null) {
            loadVideo(videoId, loudnessDb)
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
        loadVideo(videoId, loudnessDb)
    }

    private fun loadVideo(videoId: String, loudnessDb: Double?) {
        // Set BEFORE navigating, so every injection triggered by this page
        // load (onPageStarted, onPageFinished, and the delayed re-pokes
        // below) carries this song's value rather than the previous song's.
        currentLoudnessDb = loudnessDb
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