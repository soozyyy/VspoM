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
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle

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
        // Backing actions for the notification's own play/pause button.
        // Only used on Android 12 and below: from 13 onwards the system
        // derives a MediaStyle notification's buttons from the session's
        // PlaybackState actions and ignores addAction() entirely. Handled
        // here rather than via MediaButtonReceiver so no manifest receiver,
        // no MEDIA_BUTTON intent-filter and no extra routing are needed —
        // hardware buttons already reach an active session directly.
        const val ACTION_PAUSE = "com.soozyyy.vspomusic.vspo_music.action.PAUSE"
        const val ACTION_RESUME = "com.soozyyy.vspomusic.vspo_music.action.RESUME"
        const val ACTION_SKIP_NEXT = "com.soozyyy.vspomusic.vspo_music.action.SKIP_NEXT"
        const val ACTION_SKIP_PREVIOUS = "com.soozyyy.vspomusic.vspo_music.action.SKIP_PREVIOUS"
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

    // Android's handle on "this app is a media player": what the lock screen,
    // Bluetooth/wired/car buttons and the system media output switcher all
    // talk to. Created in onCreate(), released in onDestroy().
    private var mediaSession: MediaSessionCompat? = null

    // What's playing, kept as fields rather than onStartCommand() locals
    // because the notification now has to be REBUILT outside ACTION_PLAY —
    // every pause/resume re-posts it with a flipped play/pause icon and a
    // flipped ongoing flag. The fallbacks match the old buildNotification()
    // behaviour for a playVideo call that somehow arrives without them.
    private var currentTitle = "VSpo Music"
    private var currentArtist = "Playing in the background"
    private var isPlaying = false

    // Loudness of the song currently being loaded. Read by injectionScript()
    // so every injection for this page (onPageStarted, onPageFinished, and
    // the scheduled re-pokes) carries the same value. Set before loadVideo()
    // navigates, so it's always in sync with whatever page is loading.
    private var currentLoudnessDb: Double? = null

    /**
     * Diagnostic only. Logs real screen on/off under the same tag as the
     * injected script, so a STUTTER line can be tied to the exact transition
     * that triggered it.
     *
     * This exists because the page-side `visibilitychange` event does NOT
     * report the screen: for a WebView in an overlay window it only fires on
     * navigation (the document goes hidden during unload). A capture was
     * misread that way once already. ACTION_SCREEN_ON/OFF are system
     * broadcasts and are authoritative.
     */
    private val screenReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context?, intent: Intent?) {
            Log.d("VspoOverlayJS", "[vspo] SCREEN ${if (intent?.action == Intent.ACTION_SCREEN_ON) "ON" else "OFF"}")
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
        // The callbacks land on the main thread (no handler passed), which is
        // required: they all end up in evaluateJavascript(), and WebView is
        // main-thread only.
        mediaSession = MediaSessionCompat(this, "VspoMusic").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = resume()
                override fun onPause() = pause()
                override fun onStop() = stopEverything()
                override fun onSeekTo(pos: Long) = seekTo(pos / 1000.0)
                // Unlike the four above, these cannot be answered here: only
                // Dart knows the shuffle order. Hand them up and let it call
                // back down via playVideo.
                override fun onSkipToNext() = askDartFor("skipNext")
                override fun onSkipToPrevious() = askDartFor("skipPrevious")
            })
        }
        // These two can only be received at runtime — they are not deliverable
        // to a manifest-declared receiver, which is why this is registered here.
        registerReceiver(
            screenReceiver,
            android.content.IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_SCREEN_OFF)
            }
        )
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                return START_NOT_STICKY
            }

            ACTION_PAUSE -> pause()
            ACTION_RESUME -> resume()
            ACTION_SKIP_NEXT -> askDartFor("skipNext")
            ACTION_SKIP_PREVIOUS -> askDartFor("skipPrevious")

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
                    // Session state first, notification second — buildNotification()
                    // reads all of these, including the session token.
                    currentTitle = title
                    currentArtist = artist
                    isPlaying = true
                    mediaSession?.isActive = true
                    mediaSession?.setMetadata(
                        MediaMetadataCompat.Builder()
                            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
                            // Deliberately no METADATA_KEY_DURATION: without a
                            // duration the lock screen shows no scrubber, so
                            // there's no position to keep in sync with the
                            // <video> element. Artwork is a later phase.
                            .build()
                    )
                    publishState()
                    startForeground(NOTIFICATION_ID, buildNotification())
                    showOverlay(videoId, loudnessDb)
                }
            }
        }
        return START_STICKY
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "VSpo Music playback",
                NotificationManager.IMPORTANCE_LOW
            )
        )
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            this,
            requestCode,
            Intent(this, OverlayService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    /**
     * The one place the notification is assembled, from the fields above.
     * Re-called on every pause/resume, not just on a new song.
     *
     * There is deliberately no Stop button. Instead this follows the
     * Spotify/YT Music convention: ongoing (unswipeable) while playing,
     * dismissible once paused, and dismissing it runs the exact same
     * teardown the old Stop button did, via setDeleteIntent(). That keeps
     * the button row at three (Previous, Play/Pause, Next) once the skip
     * actions land, which is as many as the collapsed row fits comfortably.
     */
    private fun buildNotification(): Notification {
        val playPause = if (isPlaying) {
            NotificationCompat.Action(
                android.R.drawable.ic_media_pause,
                "Pause",
                servicePendingIntent(ACTION_PAUSE, 1)
            )
        } else {
            NotificationCompat.Action(
                android.R.drawable.ic_media_play,
                "Play",
                servicePendingIntent(ACTION_RESUME, 2)
            )
        }

        // Reusing ic_bg_service_small — already confirmed to be a valid,
        // non-adaptive notification icon (this is what fixed the earlier
        // CannotPostForegroundServiceNotificationException crash).
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle(currentTitle)
            .setContentText(currentArtist)
            .setSmallIcon(R.drawable.ic_bg_service_small)
            .setStyle(
                MediaStyle()
                    .setMediaSession(mediaSession?.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )
            // Order matters — these indices are what setShowActionsInCompactView
            // refers to. Three is about as many as the collapsed row fits.
            .addAction(
                android.R.drawable.ic_media_previous,
                "Previous",
                servicePendingIntent(ACTION_SKIP_PREVIOUS, 3)
            )
            .addAction(playPause)
            .addAction(
                android.R.drawable.ic_media_next,
                "Next",
                servicePendingIntent(ACTION_SKIP_NEXT, 4)
            )
            .setOngoing(isPlaying)
            .setDeleteIntent(servicePendingIntent(ACTION_STOP, 0))
            .build()
    }

    /** Re-posts the notification in place after a state change. */
    private fun refreshNotification() {
        // Plain NotificationManager rather than NotificationManagerCompat:
        // the latter's notify() carries a @RequiresPermission that lint flags
        // here, and this only ever updates a notification the service already
        // posted via startForeground().
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification())
    }

    /**
     * Publishes [isPlaying] to the MediaSession. Called from pause()/resume()
     * themselves rather than from their call sites, because there are now two
     * of those (Dart's MethodChannel, and the MediaSession callback driven by
     * the lock screen and hardware buttons) and publishing at each site
     * separately is how the lock screen and the in-app mini-player drift apart.
     *
     * From Android 13 on, the actions declared here are also what the system
     * renders as the notification's buttons.
     */
    private fun publishState() {
        mediaSession?.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or
                        PlaybackStateCompat.ACTION_STOP or
                        PlaybackStateCompat.ACTION_SEEK_TO or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
                )
                .setState(
                    if (isPlaying) PlaybackStateCompat.STATE_PLAYING
                    else PlaybackStateCompat.STATE_PAUSED,
                    // The real position lives in the <video> element and is
                    // only readable asynchronously (getPosition). Since no
                    // duration is published either, nothing displays it —
                    // reporting UNKNOWN is honest and costs nothing.
                    PlaybackStateCompat.PLAYBACK_POSITION_UNKNOWN,
                    1f
                )
                .build()
        )
    }

    /**
     * Sends a skip request up to Dart, which owns the shuffle order and
     * answers by calling playVideo back down. Deliberately fire-and-forget:
     * if nothing is listening (app swiped out of recents, so the Flutter
     * engine is gone — see MainActivity.events) the skip is dropped rather
     * than queued, because by the time Dart came back the request would be
     * several songs stale.
     *
     * Safe to call straight from the MediaSession callback and from
     * onStartCommand: both run on the main thread, which is also the thread
     * an EventSink must be touched from.
     */
    private fun askDartFor(event: String) {
        val sink = MainActivity.events
        if (sink == null) {
            Log.d("VspoOverlayJS", "[vspo] $event ignored - no Dart listener (app closed?)")
            return
        }
        sink.success(event)
    }

    /** Full teardown — the old Stop button's behaviour, now also reached by
     *  swiping the paused notification away and by MediaSession's onStop(). */
    private fun stopEverything() {
        removeOverlay()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
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
          // Calibration knob: the level every song is normalized to, in dB
          // relative to YouTube's -14 LUFS reference. 0 would mean "match
          // YouTube"; raise it toward 0 if the app feels too quiet, lower it
          // if you want fewer songs on the boost path.
          //
          // -6 is chosen, not arbitrary. A song only needs the Web Audio
          // boost path when it is QUIETER than this target, and Web Audio is
          // what causes the stutter — so a lower target means fewer songs can
          // ever hit it. Measured on the real 344-song catalog:
          //
          //     offset    app level   songs needing Web Audio   leveling
          //        0      -14 LUFS         24  (7.0%)           1.89 dB
          //       -6      -20 LUFS          2  (0.6%)           perfect
          //
          // It also buys headroom against FUTURE songs. Boost is capped at
          // MAX_GAIN (+12 dB), so a song more than 12 dB below target can't
          // reach it and plays slightly quiet. At offset 0 that bites at
          // -26 LUFS and one song in the catalog already does; at -6 it
          // bites at -32 LUFS, which nothing comes close to.
          //
          // Deliberately NOT set to the current quietest song (-13.93): that
          // would zero out the boost path today and silently resurrect it the
          // first time a quieter song is added, while costing 14 dB of
          // loudness for a guarantee it can't keep.
          var TARGET_OFFSET_DB = -6;
          // Bounds on what we'll do to any one song — these only catch
          // garbage data. MAX_GAIN of 4.0 is +12 dB; see the headroom note
          // above, and the catalog invariant in loudness.test.js that fails
          // if any real song ever exceeds it.
          var MIN_GAIN = 0.25;
          var MAX_GAIN = 4.0;

          // Everything logs through here (tagged so it's easy to grep in
          // Logcat).
          function log(msg) { console.log('[vspo] ' + msg); }
          log('page loaded: ' + location.href);

          // ---- stutter detector (diagnostic only, no behaviour change) ----
          // The audible glitch is a split-second dropout, far too short to see
          // in the 4-second status line. This compares the media clock against
          // the wall clock on every 500ms tick and logs ONLY when they
          // disagree, so it stays silent unless something actually goes wrong.
          //
          // The fields it records are chosen to separate the three candidate
          // causes, which need completely different fixes:
          //   readyState < 4 or buffered≈0 -> the pipeline ran dry (network or
          //     decode). Web Audio is innocent.
          //   readyState 4 with seconds buffered, yet playback stalled -> the
          //     data was ready and the SINK stalled. That's the audio output
          //     path, i.e. Web Audio / AudioTrack.
          //   dropped frames spiking at the same moment -> video decode is
          //     struggling and dragging the clock with it.
          function bufferedAhead(v) {
            try {
              for (var i = 0; i < v.buffered.length; i++) {
                if (v.buffered.start(i) <= v.currentTime && v.currentTime <= v.buffered.end(i)) {
                  return v.buffered.end(i) - v.currentTime;
                }
              }
            } catch (e) {}
            return -1;
          }

          function droppedFrames(v) {
            try {
              return v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality().droppedVideoFrames : -1;
            } catch (e) { return -1; }
          }

          // Watches TWO clocks against the wall clock, because they fail
          // independently and that difference is the whole diagnosis:
          //
          //   video.currentTime   - the media clock. Stalls on buffering,
          //                         decode trouble, or CPU starvation.
          //   ctx.currentTime     - the audio clock, advanced by rendered
          //                         samples. Stalls when the Web Audio render
          //                         thread misses its deadline.
          //
          // A previous capture showed the media clock keeping PERFECT time
          // across 76 seconds during which the glitch was audible throughout.
          // That rules out buffering/decode/CPU and points below the media
          // clock, at the audio output path — which is exactly what
          // createMediaElementSource put in there. If AUDIO drift appears
          // while VIDEO drift stays at zero, that's confirmed, and the fix is
          // to stop routing audio through Web Audio for the ~93% of songs
          // that only need turning down (video.volume does that natively).
          function checkStutter(v) {
            if (!v || v.paused || v.ended) { window.__vspoClock = null; return; }
            // readyState < 3 (HAVE_FUTURE_DATA) means the element hasn't got
            // going yet — that's song startup, not a stutter. Without this,
            // every page load produced a burst of false positives at t=0.00
            // that buried the real events.
            if (v.readyState < 3) { window.__vspoClock = null; return; }
            var ctx = window.__vspoAudioCtx;
            var now = Date.now();
            var prev = window.__vspoClock;
            window.__vspoClock = {
              wall: now,
              play: v.currentTime,
              audio: ctx ? ctx.currentTime : -1,
              dropped: droppedFrames(v)
            };
            if (!prev) return;
            var wallMs = now - prev.wall;
            var playMs = (v.currentTime - prev.play) * 1000;
            // currentTime going backwards is a seek or a loop, never a
            // stutter — and without this guard a seek backwards looks like a
            // huge one. A seek FORWARD needs no guard: it makes playMs large,
            // so lostMs goes negative and nothing fires.
            if (playMs < 0) return;
            // No upper bound on purpose: if the tick itself gets delayed AND
            // playback stalls with it, that's exactly what we want to see.
            var videoLost = wallMs - playMs;
            // The audio clock never rewinds, so it needs no seek guard.
            var audioLost = (prev.audio < 0 || !ctx)
              ? 0
              : wallMs - (ctx.currentTime - prev.audio) * 1000;
            // Observed noise floor on the media clock is ~20ms; 80 clears it.
            if (videoLost < 80 && audioLost < 80) return;
            log('STUTTER videoLost=' + videoLost.toFixed(0) + 'ms' +
                ' audioLost=' + audioLost.toFixed(0) + 'ms' +
                ' wall=' + wallMs + 'ms' +
                ' readyState=' + v.readyState +
                ' bufferedAhead=' + bufferedAhead(v).toFixed(1) + 's' +
                ' droppedFrames=+' + (window.__vspoClock.dropped - prev.dropped) +
                ' audioCtx=' + (ctx ? ctx.state : 'none') +
                ' t=' + v.currentTime.toFixed(2));
          }

          // NOTE: this fires on navigation (the document goes hidden during
          // unload), NOT on the screen turning off — an earlier capture was
          // misread because of that. Real screen state is logged from Kotlin
          // instead, as SCREEN ON / SCREEN OFF under the same tag. Kept only
          // because it marks page teardown, which is genuinely useful.
          document.addEventListener('visibilitychange', function() {
            var v = document.querySelector('video');
            log('document ' + document.visibilityState + ' (navigation, not screen)' +
                ' at t=' + (v ? v.currentTime.toFixed(2) : 'n/a'));
          });

          // What to do with this song, decided purely from its loudness.
          // Pure function, no DOM — loudness.test.js lifts it from this file
          // and checks the routing, so it can't drift from what ships.
          //
          //   'leave'  - no catalog value. Touch NOTHING: YouTube's own
          //              normalization is already on the element and stomping
          //              it is what caused the original volume problem.
          //   'volume' - song needs turning DOWN. video.volume does that
          //              natively, so NO Web Audio at all.
          //   'boost'  - song needs turning UP. video.volume caps at 1, so
          //              this is the only case that needs a gain node.
          //
          // On the real 344-song catalog that's 320 'volume', 24 'boost' —
          // i.e. 93% of playback never enters the Web Audio graph.
          function plan(db) {
            if (db === null || !isFinite(db)) return { mode: 'leave', target: 1 };
            var target = Math.pow(10, (TARGET_OFFSET_DB - db) / 20);
            return { mode: target <= 1 ? 'volume' : 'boost', target: target };
          }

          // Gain for the boost path only. ytVol is whatever YouTube left on
          // the element (1.0 for anything it declined to lift), so dividing
          // by it means we can never stack our boost on top of an attenuation
          // YouTube already applied. Also lifted by the test.
          function boostGain(target, ytVol) {
            var v0 = (ytVol > 0 && ytVol <= 1) ? ytVol : 1;
            return Math.min(MAX_GAIN, Math.max(MIN_GAIN, target / v0));
          }

          // Keeps an element at its target volume. Cheap enough to call every
          // tick: setting .volume to the value it already holds is a no-op in
          // the media element, and this self-heals if YouTube (or anything
          // else) moves it afterwards.
          function enforceVolume(v) {
            if (!v || v.__vspoTargetVol === undefined) return;
            if (Math.abs(v.volume - v.__vspoTargetVol) <= 0.005) return;
            var before = v.volume;
            v.volume = v.__vspoTargetVol;
            log('volume -> ' + v.__vspoTargetVol.toFixed(3) +
                ' (was ' + before.toFixed(3) + ')');
          }

          function applyLoudness(v) {
            if (v.__vspoTuned) { return; }
            v.__vspoTuned = true;
            var p = plan(loudnessDb);
            if (p.mode === 'leave') {
              log('no loudness for this song - leaving YouTube\'s own level alone');
              return;
            }
            if (p.mode === 'volume') {
              // The whole normalization for this song, with no AudioContext,
              // no source node and no limiter. YouTube has usually already
              // set exactly this value; enforceVolume only acts if it hasn't.
              v.__vspoTargetVol = p.target;
              log('volume path: target=' + p.target.toFixed(3) +
                  ' (loudnessDb=' + loudnessDb +
                  ', ytVolume=' + v.volume.toFixed(3) + ') - no Web Audio');
              enforceVolume(v);
              return;
            }
            buildBoostGraph(v, p.target);
          }

          function buildBoostGraph(v, target) {
            // Belt-and-suspenders guard directly on the element itself —
            // createMediaElementSource() can only ever be called ONCE for
            // a given underlying media element/resource; calling it twice
            // throws InvalidStateError and leaves that video's audio graph
            // broken for the rest of the song.
            if (v.__vspoAudioSetup) {
              log('boost graph skipped, element already set up');
              return;
            }
            v.__vspoAudioSetup = true;
            try {
              if (!window.__vspoAudioCtx) {
                // 'playback' asks for the LARGEST output buffer rather than
                // the default 'interactive' (smallest). Routing audio through
                // Web Audio means every load spike has to be absorbed by that
                // buffer; if it isn't, the render thread fills the gap with
                // silence and you hear a click. Latency is irrelevant for
                // music, so trade it for headroom. Only reached on the ~7% of
                // songs that need a boost at all.
                window.__vspoAudioCtx = new (window.AudioContext || window.webkitAudioContext)({ latencyHint: 'playback' });
                log('created AudioContext (latencyHint=playback), initial state=' + window.__vspoAudioCtx.state);
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

              // One gain, decided once, held for the whole song. The number
              // comes from YouTube's analysis of the entire track, which is
              // strictly better than anything we could estimate from the
              // first second and a half of audio.
              //
              // YouTube never boosts, so on this path v.volume is normally 1
              // and the gain is the whole correction. Dividing by v.volume
              // anyway means that if YouTube ever DID attenuate this element,
              // we can't stack a boost on top of it.
              v.__vspoRetune = function() {
                var g = boostGain(target, v.volume);
                if (Math.abs(g - gainNode.gain.value) < 0.001) return;
                gainNode.gain.value = g;
                log('gain retuned to ' + g.toFixed(3) +
                    ' (ytVolume=' + v.volume.toFixed(3) + ')');
              };
              v.__vspoLastVol = v.volume;
              gainNode.gain.value = boostGain(target, v.volume);
              log('boost path: gain=' + gainNode.gain.value.toFixed(3) +
                  ' (loudnessDb=' + loudnessDb +
                  ', target=' + target.toFixed(3) +
                  ', ytVolume=' + v.volume.toFixed(3) + ')');

              log('boost graph attached to this video element');
            } catch (e) {
              log('boost graph setup FAILED: ' + e);
            }
          }

          setInterval(function() {
            tickCount++;
            var v = document.querySelector('video');

            // First thing in the tick, so its wall-clock reading is as close
            // as possible to a fixed 500ms cadence.
            checkStutter(v);

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
              applyLoudness(v);
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
              // Volume path: hold the element at its target. Self-healing if
              // YouTube moves it after we set it, and a no-op otherwise.
              enforceVolume(v);
              // Boost path: pick up YouTube's attenuation if it lands after
              // the graph was built. Only fires on an actual change.
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
        isPlaying = false
        publishState()
        refreshNotification()
    }

    /** Resumes the underlying <video> element directly (play/pause toggle). */
    fun resume() {
        webView?.evaluateJavascript(
            "(function(){window.__vspoUserPaused = false; var v=document.querySelector('video'); if(v) v.play();})();",
            null
        )
        isPlaying = true
        publishState()
        refreshNotification()
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
        // Leaving an active session behind makes the system keep routing
        // hardware media buttons at a service that no longer exists.
        mediaSession?.isActive = false
        mediaSession?.release()
        mediaSession = null
        // Leaking a registered receiver past the service's life logs a loud
        // framework warning and holds a reference to this service.
        try {
            unregisterReceiver(screenReceiver)
        } catch (e: IllegalArgumentException) {
            // Never registered (or already unregistered) — safe to ignore.
        }
        removeOverlay()
        super.onDestroy()
    }
}