part of 'main.dart';

// Dart handles for web/player.js: the YouTube player, browser storage and
// fetch. This file and player.js replace the app's MethodChannel to
// OverlayService.kt, its on-device files, and dart:io's HttpClient.

@JS('vspoPlayer.play')
external void _jsPlay(String videoId, double volume);

@JS('vspoPlayer.pause')
external void _jsPause();

@JS('vspoPlayer.resume')
external void _jsResume();

@JS('vspoPlayer.seek')
external void _jsSeek(double seconds);

@JS('vspoPlayer.setVolume')
external void _jsSetVolume(double volume);

/// JSON: {position, duration, paused, ended, error}.
@JS('vspoPlayer.state')
external String _jsState();

@JS('vspoStore.get')
external String? _storeGet(String key);

@JS('vspoStore.set')
external void _storeSet(String key, String value);

@JS('vspoFetchText')
external JSPromise<JSString?> _jsFetchText(String url);

/// Body of [url], or null on any failure (offline, non-200, timeout).
Future<String?> _fetchText(String url) async {
  try {
    return (await _jsFetchText(url).toDart)?.toDart;
  } catch (_) {
    return null;
  }
}
