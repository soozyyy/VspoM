// VspoM website: the browser half of playback, storage and fetching.
// lib/web_bridge.dart calls these through dart:js_interop.
//
// Playback uses YouTube's official IFrame Player API in an invisible player.
// The app's OverlayService.kt is the phone equivalent; all the sequencing
// (shuffle, next, queue) stays in Dart, so this side only ever knows
// "play this video ID".
(function () {
  var player = null;
  var ready = false;
  var pending = null; // [videoId, volume] asked for before the player loaded
  var currentId = null;
  var volume = 100;
  var error = null; // YouTube's error code for currentId, cleared by play()
  var startedAt = 0;

  function create() {
    var box = document.createElement('div');
    // Invisible and click-through, but kept in the viewport at the API's
    // 200x200 minimum, so the browser doesn't treat it as hidden.
    box.style.cssText =
      'position:fixed;right:0;bottom:0;width:200px;height:200px;' +
      'opacity:0;pointer-events:none;z-index:-1;';
    var slot = document.createElement('div');
    slot.id = 'vspo-yt';
    box.appendChild(slot);
    document.body.appendChild(box);
    player = new YT.Player('vspo-yt', {
      width: 200,
      height: 200,
      playerVars: { autoplay: 1, controls: 0, disablekb: 1, fs: 0, playsinline: 1, rel: 0 },
      events: {
        onReady: function () {
          ready = true;
          if (pending) {
            var p = pending;
            pending = null;
            window.vspoPlayer.play(p[0], p[1]);
          }
        },
        // YouTube may reset volume/mute on a new video; put ours back.
        onStateChange: function (e) {
          if (e.data === YT.PlayerState.PLAYING) {
            player.unMute();
            player.setVolume(volume);
          }
        },
        // 100 = removed/private, 101/150 = uploader blocks other sites,
        // 2/5 = bad ID / player trouble.
        onError: function (e) { error = e.data; }
      }
    });
  }

  window.onYouTubeIframeAPIReady = create;
  var tag = document.createElement('script');
  tag.src = 'https://www.youtube.com/iframe_api';
  document.head.appendChild(tag);

  window.vspoPlayer = {
    play: function (videoId, vol) {
      currentId = videoId;
      volume = vol;
      error = null;
      startedAt = Date.now();
      if (!ready) { pending = [videoId, vol]; return; }
      player.setVolume(vol);
      player.loadVideoById(videoId);
    },
    pause: function () { if (ready) player.pauseVideo(); },
    resume: function () { if (ready) player.playVideo(); },
    seek: function (seconds) { if (ready) player.seekTo(seconds, true); },
    setVolume: function (vol) { volume = vol; if (ready) player.setVolume(vol); },
    // JSON: {position, duration, paused, ended, error}
    state: function () {
      if (!ready || !currentId) return JSON.stringify({ error: error });
      var st = player.getPlayerState();
      return JSON.stringify({
        position: player.getCurrentTime() || 0,
        duration: player.getDuration() || 0,
        paused: st === YT.PlayerState.PAUSED,
        // Ignored right after play(): the old video can still report ENDED
        // for a moment before the new one starts loading.
        ended: st === YT.PlayerState.ENDED && Date.now() - startedAt > 1500,
        error: error
      });
    }
  };

  // localStorage, which can throw (private windows, blocked site data).
  // Prefixed: every github.io site of the same account shares one storage.
  window.vspoStore = {
    get: function (key) { try { return localStorage.getItem('vspom:' + key); } catch (e) { return null; } },
    set: function (key, value) { try { localStorage.setItem('vspom:' + key, value); } catch (e) {} }
  };

  // Text of a URL, or null on any failure. 10 s timeout.
  window.vspoFetchText = function (url) {
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, 10000);
    return fetch(url, { signal: ctl.signal, cache: 'no-cache' })
      .then(function (r) { return r.ok ? r.text() : null; })
      .catch(function () { return null; })
      .finally(function () { clearTimeout(timer); });
  };
})();
