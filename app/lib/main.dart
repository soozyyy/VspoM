import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ---------------------------------------------------------------------------
// PHASE 5 — real playlist UI
//
// The background-playback engine (native OverlayService.kt, reached via this
// MethodChannel) is confirmed working: audio survives Home, screen off, and
// app switching. This screen replaces the Phase 4 test harness with the
// actual app UI — a simplified Spotify-style playlist screen for the VSpo
// catalog (currently backed by mock data; will be swapped for the real
// catalog.json fetched from GitHub raw content once the scraper has run).
//
// Deliberately OMITTED vs. the Spotify reference screenshot, per explicit
// user instruction: the Add/Edit/Sort management row, the bottom navigation
// bar, and any manual curation UI — the catalog is auto-fetched from
// vspodex.app and updates on its own, so there's nothing to curate in-app.
// ---------------------------------------------------------------------------

void main() {
  runApp(const VspoMusicApp());
}

class Song {
  final String videoId;
  final String title;
  final String artist;
  final String thumbnailUrl;
  final Duration duration;

  const Song({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    required this.duration,
  });

  factory Song.fromJson(Map<String, dynamic> json) {
    return Song(
      videoId: json['videoId'] as String,
      title: json['title'] as String,
      artist: json['artist'] as String,
      thumbnailUrl: json['thumbnailUrl'] as String? ??
          'https://i.ytimg.com/vi/${json['videoId']}/mqdefault.jpg',
      duration: Duration(seconds: json['durationSeconds'] as int? ?? 0),
    );
  }
}

// Placeholder catalog so the UI can be built/iterated on before the real
// scraper output (343 songs from vspodex.app) is wired in. Swap
// `_mockCatalog` for a fetch from raw.githubusercontent.com/.../catalog.json
// later — the rest of the UI only depends on `List<Song>`.
List<Song> _mockCatalog() {
  final titles = [
    'Kirinuki Blues', 'Neon Handshake', 'Midnight Karaoke', 'Static Bloom',
    'Overclock Heart', 'Paper Moon Relay', 'Glitch Lullaby', 'Vermillion Wave',
    'Aftercare', 'Loop Me Twice', 'Signal Flare', 'Confetti Static',
  ];
  final artists = [
    'Kson', 'Kanae', 'Suzu Honjo', 'Ao Mishiro', 'Kaida Haru', 'Rikka',
  ];
  final rng = Random(7);
  return List.generate(343, (i) {
    final title = titles[i % titles.length] +
        (i >= titles.length ? ' (v${(i ~/ titles.length) + 1})' : '');
    final artist = artists[i % artists.length];
    final seconds = 150 + rng.nextInt(120);
    return Song(
      videoId: 'dQw4w9WgXcQ',
      title: title,
      artist: artist,
      thumbnailUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg',
      duration: Duration(seconds: seconds),
    );
  });
}

class VspoMusicApp extends StatelessWidget {
  const VspoMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VSpo Music',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.deepPurple,
        scaffoldBackgroundColor: const Color(0xFF121212),
        useMaterial3: true,
      ),
      home: const PlaylistScreen(),
    );
  }
}

enum PlaybackStatus { idle, needsPermission, playing }

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen>
    with WidgetsBindingObserver {
  static const _overlayChannel = MethodChannel('vspo_music/overlay');

  late final List<Song> _catalog;
  List<int> _playOrder = [];
  int _playOrderIndex = 0;
  int? _currentSongIndex;
  bool? _hasPermission;
  bool _playing = false;
  bool _isPaused = false;

  // Progress-bar state, refreshed by polling the native side.
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _dragValueSeconds; // non-null while the user is actively dragging
  Timer? _progressTimer;
  bool _autoAdvancing = false;

  @override
  void initState() {
    super.initState();
    _catalog = _mockCatalog();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollPosition(),
    );
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final granted =
        await _overlayChannel.invokeMethod<bool>('hasOverlayPermission');
    setState(() => _hasPermission = granted ?? false);
  }

  Future<void> _requestPermission() async {
    await _overlayChannel.invokeMethod('requestOverlayPermission');
  }

  Duration get _totalDuration =>
      _catalog.fold(Duration.zero, (sum, s) => sum + s.duration);

  String _formatTotalDuration() {
    final total = _totalDuration;
    final hours = total.inHours;
    final minutes = total.inMinutes.remainder(60);
    if (hours > 0) return '$hours hr $minutes min';
    return '$minutes min';
  }

  String _formatTrackDuration(Duration d) {
    final minutes = d.inMinutes;
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _newShuffleOrder({int? startingWith}) {
    final indices = List.generate(_catalog.length, (i) => i)..shuffle();
    if (startingWith != null) {
      indices.remove(startingWith);
      indices.insert(0, startingWith);
    }
    _playOrder = indices;
    _playOrderIndex = 0;
  }

  Future<void> _playSongAt(int orderIndex) async {
    if (_playOrder.isEmpty) return;
    if (orderIndex < 0) return;
    if (orderIndex >= _playOrder.length) {
      // Reached the end of the shuffled list — reshuffle and loop forever.
      _newShuffleOrder();
      orderIndex = 0;
    }
    final songIndex = _playOrder[orderIndex];
    _playOrderIndex = orderIndex;
    setState(() {
      _currentSongIndex = songIndex;
      _playing = true;
      _isPaused = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _dragValueSeconds = null;
    });
    await _overlayChannel.invokeMethod(
      'playVideo',
      {'videoId': _catalog[songIndex].videoId},
    );
  }

  Future<void> _shufflePlayAll() async {
    if (_hasPermission != true) {
      await _requestPermission();
      return;
    }
    _newShuffleOrder();
    await _playSongAt(0);
  }

  Future<void> _playSpecificSong(int songIndex) async {
    if (_hasPermission != true) {
      await _requestPermission();
      return;
    }
    _newShuffleOrder(startingWith: songIndex);
    await _playSongAt(0);
  }

  Future<void> _next() async {
    await _playSongAt(_playOrderIndex + 1);
  }

  Future<void> _previous() async {
    // Mirrors typical player behavior: walk back within the songs already
    // queued up in this shuffle pass. If we're at the very first song,
    // there's nothing before it, so this is a no-op.
    if (_playOrderIndex <= 0) return;
    await _playSongAt(_playOrderIndex - 1);
  }

  Future<void> _togglePlayPause() async {
    if (_currentSongIndex == null) return;
    if (_isPaused) {
      await _overlayChannel.invokeMethod('resume');
    } else {
      await _overlayChannel.invokeMethod('pause');
    }
    setState(() => _isPaused = !_isPaused);
  }

  Future<void> _seekTo(Duration target) async {
    await _overlayChannel.invokeMethod('seek', {
      'seconds': target.inMilliseconds / 1000.0,
    });
    setState(() {
      _position = target;
      _dragValueSeconds = null;
    });
  }

  Future<void> _pollPosition() async {
    if (_currentSongIndex == null || _dragValueSeconds != null) return;
    Map<dynamic, dynamic>? info;
    try {
      info = await _overlayChannel.invokeMapMethod<dynamic, dynamic>(
        'getPosition',
      );
    } catch (_) {
      return;
    }
    if (!mounted || info == null) return;

    final positionSeconds = (info['position'] as num?)?.toDouble() ?? 0.0;
    final durationSeconds = (info['duration'] as num?)?.toDouble() ?? 0.0;
    final paused = info['paused'] as bool? ?? _isPaused;

    setState(() {
      _position = Duration(milliseconds: (positionSeconds * 1000).round());
      if (durationSeconds > 0) {
        _duration = Duration(milliseconds: (durationSeconds * 1000).round());
      }
      _isPaused = paused;
    });

    // Auto-advance once the current song finishes, so shuffle-play-all keeps
    // going (and loops via _playSongAt's own wraparound) without the user
    // having to tap "next" manually every time.
    final nearEnd = _duration.inMilliseconds > 0 &&
        _position.inMilliseconds >= _duration.inMilliseconds - 750;
    if (nearEnd && !_autoAdvancing && !paused) {
      _autoAdvancing = true;
      await _next();
      _autoAdvancing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentSong =
        _currentSongIndex != null ? _catalog[_currentSongIndex!] : null;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildHeader()),
            if (_hasPermission == false) SliverToBoxAdapter(child: _buildPermissionBanner()),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildTrackRow(index),
                childCount: _catalog.length,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
      bottomNavigationBar: currentSong == null
          ? null
          : _buildMiniPlayer(currentSong),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.deepPurple.shade400,
                      Colors.indigo.shade900,
                    ],
                  ),
                ),
                child: const Center(
                  child: Icon(Icons.music_note, size: 72, color: Colors.white70),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'VSpo Music',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Curated by vspodex.app · ${_catalog.length} songs · ${_formatTotalDuration()}',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _shufflePlayAll,
                  icon: const Icon(Icons.shuffle),
                  label: Text(_playing ? 'Shuffling…' : 'Shuffle Play All'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.deepPurple,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.deepPurpleAccent),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Grant "Draw over other apps" so music keeps playing when your '
              'screen is off or you switch apps.',
              style: TextStyle(fontSize: 12.5, color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: _requestPermission,
            child: const Text('Grant'),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackRow(int index) {
    final song = _catalog[index];
    final isCurrent = _currentSongIndex == index;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Image.network(
          song.thumbnailUrl,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 48,
            height: 48,
            color: Colors.grey.shade800,
            child: const Icon(Icons.music_note, color: Colors.white38, size: 20),
          ),
        ),
      ),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isCurrent ? Colors.deepPurpleAccent : Colors.white,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.grey.shade400, fontSize: 12.5),
      ),
      trailing: Text(
        _formatTrackDuration(song.duration),
        style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
      ),
      onTap: () => _playSpecificSong(index),
    );
  }

  Widget _buildMiniPlayer(Song song) {
    final durationMs = _duration.inMilliseconds;
    final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final sliderValue = (_dragValueSeconds != null
            ? _dragValueSeconds! * 1000
            : _position.inMilliseconds.toDouble())
        .clamp(0.0, sliderMax);

    return Material(
      color: const Color(0xFF1E1E1E),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2.5,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                  activeTrackColor: Colors.deepPurpleAccent,
                  inactiveTrackColor: Colors.grey.shade700,
                  thumbColor: Colors.deepPurpleAccent,
                ),
                child: Slider(
                  min: 0,
                  max: sliderMax,
                  value: sliderValue,
                  onChanged: durationMs > 0
                      ? (value) => setState(() => _dragValueSeconds = value / 1000)
                      : null,
                  onChangeEnd: durationMs > 0
                      ? (value) => _seekTo(
                            Duration(milliseconds: value.round()),
                          )
                      : null,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        song.thumbnailUrl,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 44,
                          height: 44,
                          color: Colors.grey.shade800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13.5),
                          ),
                          Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: Colors.grey.shade400, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_previous, color: Colors.white),
                      onPressed: _previous,
                    ),
                    IconButton(
                      icon: Icon(
                        _isPaused ? Icons.play_circle_fill : Icons.pause_circle_filled,
                        color: Colors.white,
                        size: 32,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      onPressed: _next,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
