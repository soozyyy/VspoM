import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

// ---------------------------------------------------------------------------
// PHASE 2 PROOF OF CONCEPT
//
// Phase 1 proved background playback works at all (screen off, other apps
// open, lock-screen controls) using a plain test MP3. This phase replaces
// that hardcoded URL with a real YouTube audio stream, resolved entirely
// on-device via youtube_explode_dart — no server involved anywhere.
//
// Test track: "星座になれたら" by 藍沢エマ / Aizawa Ema (video ID I84zUHUvHWE),
// one of the tracks visible on vspodex.app's /music page.
//
// Known gotcha (see youtube_explode_dart issue #332): calling
// `.withHighestBitrate()` directly can 403 on some videos even though a
// manually-sorted pick of the same streams works fine. So instead of relying
// on that shortcut, we sort the audio-only streams by bitrate ourselves and
// try them highest-first, falling back to the next one down if a stream
// fails to actually start playing.
// ---------------------------------------------------------------------------

const testVideoId = 'I84zUHUvHWE';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.soozyyy.vspomusic.channel.audio',
    androidNotificationChannelName: 'VSpo Music playback',
    androidNotificationOngoing: true,
  );
  runApp(const VspoMusicApp());
}

class VspoMusicApp extends StatelessWidget {
  const VspoMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VSpo Music (POC)',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: const PlaybackTestPage(),
    );
  }
}

class PlaybackTestPage extends StatefulWidget {
  const PlaybackTestPage({super.key});

  @override
  State<PlaybackTestPage> createState() => _PlaybackTestPageState();
}

class _PlaybackTestPageState extends State<PlaybackTestPage> {
  final _player = AudioPlayer();
  bool _loading = true;
  String? _error;
  String? _statusLine;
  String _trackTitle = '';
  String _trackArtist = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _statusLine = 'Fetching video info…';
    });

    final ytClient = yt.YoutubeExplode();
    try {
      final video = await ytClient.videos.get(testVideoId);
      _trackTitle = video.title;
      _trackArtist = video.author;

      setState(() => _statusLine = 'Resolving audio stream…');
      final manifest = await ytClient.videos.streamsClient.getManifest(
        testVideoId,
      );
      final audioStreams = manifest.audioOnly.sortByBitrate().reversed
          .toList(); // highest bitrate first

      if (audioStreams.isEmpty) {
        throw Exception('No audio-only streams found for this video.');
      }

      // Try streams highest-bitrate first, falling back on failure — some
      // individual streams can 403 even when others from the same video work.
      Object? lastError;
      for (final stream in audioStreams) {
        try {
          setState(
            () => _statusLine =
                'Trying stream (${stream.bitrate.kiloBitsPerSecond.round()} kbps)…',
          );
          await _player.setAudioSource(
            AudioSource.uri(
              stream.url,
              tag: MediaItem(
                id: testVideoId,
                title: _trackTitle,
                artist: _trackArtist,
              ),
            ),
          );
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          continue;
        }
      }

      if (lastError != null) {
        throw lastError;
      }

      setState(() {
        _loading = false;
        _statusLine = null;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    } finally {
      ytClient.close();
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('VSpo Music — On-Device YouTube Audio Test'),
      ),
      body: Center(
        child: _loading
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  if (_statusLine != null) ...[
                    const SizedBox(height: 16),
                    Text(_statusLine!),
                  ],
                ],
              )
            : _error != null
            ? Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Failed to load audio:\n$_error',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      '$_trackTitle\n$_trackArtist\n\n'
                      'Hit play, then lock your phone or switch apps.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 24),
                  StreamBuilder<PlayerState>(
                    stream: _player.playerStateStream,
                    builder: (context, snapshot) {
                      final playing = snapshot.data?.playing ?? false;
                      return IconButton(
                        iconSize: 72,
                        icon: Icon(
                          playing
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                        ),
                        onPressed: () {
                          if (playing) {
                            _player.pause();
                          } else {
                            _player.play();
                          }
                        },
                      );
                    },
                  ),
                ],
              ),
      ),
    );
  }
}
