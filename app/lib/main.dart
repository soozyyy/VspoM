import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';

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
  // catalog-scraper/scrape.js also captures vspodex.app's romanized artist
  // slug (e.g. "yakumo-beni" for 八雲べに) from the artist page URL. It's
  // what lets search match a romaji query against a kanji/kana artist name,
  // the same way vspodex.app's own search does — see _matchesSearch below.
  final String? artistSlug;
  // catalog-scraper/scrape.js reads vspodex.app's public page, which doesn't
  // expose track length anywhere in the DOM — so this is only known once a
  // song has actually started playing and the native side reports it via
  // getPosition(). Null means "not known yet".
  final Duration? duration;
  // The artist's real profile picture — usually their YouTube channel
  // avatar (a yt3.ggpht.com URL), occasionally a Twitch avatar for members
  // who stream there instead — scraped once per artist from vspodex.app's
  // own artist page (scrape.js's avatar-crawl phase) and duplicated onto
  // every song by that artist, same as artistName/artistSlug. Null for a
  // catalog.json from before this field existed, or if that artist's page
  // didn't expose one; callers fall back to a song thumbnail in that case
  // (see _PlaylistScreenState._suggestions).
  final String? artistAvatarUrl;

  const Song({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    this.artistSlug,
    this.duration,
    this.artistAvatarUrl,
  });

  // Matches catalog.json as written by catalog-scraper/scrape.js:
  // { videoId, title, artistName, artistSlug, thumbnail, artistAvatarUrl }
  factory Song.fromJson(Map<String, dynamic> json) {
    final videoId = json['videoId'] as String;
    return Song(
      videoId: videoId,
      title: (json['title'] as String?) ?? 'Untitled',
      artist: (json['artistName'] as String?) ??
          (json['artist'] as String?) ??
          'Unknown artist',
      thumbnailUrl: (json['thumbnail'] as String?) ??
          (json['thumbnailUrl'] as String?) ??
          'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
      artistSlug: json['artistSlug'] as String?,
      duration: json['durationSeconds'] != null
          ? Duration(seconds: json['durationSeconds'] as int)
          : null,
      artistAvatarUrl: json['artistAvatarUrl'] as String?,
    );
  }

  // Search matching used by the playlist screen's search box. Matches on
  // title, the artist's display name (often kanji/kana), AND the artist's
  // romanized slug — so typing "yaku" finds 八雲べに (slug "yakumo-beni"),
  // the same behavior vspodex.app's own search has, even though "yaku"
  // never appears in the kanji itself.
  bool matchesSearch(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase().trim();
    if (title.toLowerCase().contains(q)) return true;
    return artistMatches(q);
  }

  // Artist-only half of matchesSearch, split out so the search-suggestions
  // dropdown (_PlaylistScreenState._suggestions) can test "does this song's
  // artist match?" without re-deriving the romaji/slug logic. Expects `q`
  // already lowercased/trimmed by the caller.
  bool artistMatches(String q) {
    if (artist.toLowerCase().contains(q)) return true;
    final slug = artistSlug?.toLowerCase() ?? '';
    if (slug.isEmpty) return false;
    // Plain substring already covers prefix-style queries like "yaku" ->
    // "yakumo-beni". Also compare with hyphens/spaces stripped from both
    // sides so a full-name query like "yakumo beni" matches the hyphenated
    // slug too.
    if (slug.contains(q)) return true;
    final slugCompact = slug.replaceAll('-', '');
    final qCompact = q.replaceAll(RegExp(r'[\s-]'), '');
    return qCompact.isNotEmpty && slugCompact.contains(qCompact);
  }
}

// A GitHub Actions workflow (.github/workflows/refresh-catalog.yml) re-runs
// catalog-scraper/scrape.js on a schedule and commits the refreshed
// catalog.json straight to the repo — on GitHub's own servers, not this
// app, not any PC. This is that file's raw content: a plain JSON GET, no
// scraping happens on-device. Update the org/repo/branch here if the repo
// ever moves.
const _remoteCatalogUrl =
    'https://raw.githubusercontent.com/soozyyy/VspoM/main/catalog-scraper/catalog.json';

/// Loads the VSpo catalog, freshest source first:
/// 1. Live fetch from GitHub (_remoteCatalogUrl) — picks up whatever the
///    scheduled scrape last found, no app rebuild needed.
/// 2. The copy bundled at build time as assets/catalog.json, for when
///    there's no network yet (first launch, airplane mode, etc.).
/// 3. Mock placeholder data, so the app still runs before either exists.
Future<List<Song>> _loadCatalog() async {
  final remote = await _fetchRemoteCatalog();
  if (remote != null && remote.isNotEmpty) return remote;

  try {
    final raw = await rootBundle.loadString('assets/catalog.json');
    final decoded = jsonDecode(raw) as List<dynamic>;
    if (decoded.isNotEmpty) {
      return decoded
          .map((e) => Song.fromJson(e as Map<String, dynamic>))
          .toList();
    }
  } catch (_) {
    // Fall through to mock data below.
  }
  return _mockCatalog();
}

Future<List<Song>?> _fetchRemoteCatalog() async {
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    final request = await client
        .getUrl(Uri.parse(_remoteCatalogUrl))
        .timeout(const Duration(seconds: 6));
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return null;
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as List<dynamic>;
    return decoded
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    // Offline, DNS failure, GitHub hiccup, malformed JSON, etc. — the
    // bundled-asset fallback in _loadCatalog() covers all of these.
    return null;
  } finally {
    client.close(force: true);
  }
}

// Placeholder catalog used until catalog.json has real entries — see
// _loadCatalog() above.
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

// Zoom scale used only by the big now-playing header thumbnail (still an
// AspectRatio(1) square there) — kept as a named constant for that one call
// site. NOT used by _ThumbnailImage below anymore: an earlier version of
// this file zoomed every thumbnail in further, on the theory that some
// vspodex.app/YouTube thumbnails had black letterbox bars baked into the
// JPEG pixels. Checked that directly (sampled actual thumbnail pixels) —
// they don't. The real cause of "squished" list thumbnails was simpler:
// they were being forced into a square box, cropping ~44% off a 16:9 video
// thumbnail's width. _ThumbnailImage now takes an explicit width/height so
// callers can size it to match the source's actual aspect ratio instead.
const _thumbnailZoomScale = 1.3;

// A cached-network thumbnail with a shared placeholder/error look, used for
// every video thumbnail and artist avatar in the app (track rows, the mini
// player, the search-suggestions dropdown). Pass width/height matching the
// source image's real aspect ratio (16:9 for a video thumbnail, square for
// a real profile photo) so BoxFit.cover has little or nothing to crop.
class _ThumbnailImage extends StatelessWidget {
  const _ThumbnailImage({
    required this.url,
    required this.width,
    required this.height,
    this.borderRadius = 4,
    this.errorIcon = Icons.music_note,
  });

  final String url;
  final double width;
  final double height;
  final double borderRadius;
  final IconData errorIcon;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: width,
        height: height,
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          // Decode straight to roughly the size this is ever shown at (x2
          // for high-DPI) instead of whatever huge resolution the source
          // serves — avoids paying full-res decode cost for a tiny
          // on-screen image.
          memCacheWidth: (width * 2).round(),
          memCacheHeight: (height * 2).round(),
          fadeInDuration: const Duration(milliseconds: 80),
          placeholder: (_, __) => Container(color: Colors.grey.shade800),
          errorWidget: (_, __, ___) => Container(
            color: Colors.grey.shade800,
            child: Icon(
              errorIcon,
              color: Colors.white38,
              size: (width < height ? width : height) * 0.4,
            ),
          ),
        ),
      ),
    );
  }
}

class VspoMusicApp extends StatelessWidget {
  const VspoMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VspoM',
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

  List<Song> _catalog = [];
  bool _loadingCatalog = true;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  List<int> _playOrder = [];
  int _playOrderIndex = 0;
  int? _currentSongIndex;
  bool? _hasPermission;
  bool? _hasNotificationPermission;
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
    WidgetsBinding.instance.addObserver(this);
    // Repaints so the suggestions dropdown appears/disappears as the search
    // field gains/loses focus (see _suggestions / _buildSuggestions below).
    _searchFocusNode.addListener(() => setState(() {}));
    _checkPermission();
    _loadCatalog().then((songs) {
      if (!mounted) return;
      setState(() {
        _catalog = songs;
        _loadingCatalog = false;
      });
    });
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollPosition(),
    );
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Original-catalog indices whose song matches the current search query, in
  // catalog order. Kept as (originalIndex, song) pairs so tapping a filtered
  // row, and highlighting the currently-playing row, still refer back to the
  // right index in _catalog (shuffle order is also built from _catalog
  // indices, so this doesn't disturb playback).
  List<int> get _visibleIndices {
    if (_searchQuery.isEmpty) {
      return List.generate(_catalog.length, (i) => i);
    }
    final result = <int>[];
    for (var i = 0; i < _catalog.length; i++) {
      if (_catalog[i].matchesSearch(_searchQuery)) result.add(i);
    }
    return result;
  }

  // Autocomplete rows shown under the search bar while typing — e.g. typing
  // "su" surfaces the artist Sumire, using her real profile picture when
  // catalog.json has one (artistAvatarUrl — vspodex.app's own artist page,
  // scraped once per artist; usually their YouTube channel avatar), falling
  // back to one of her song thumbnails for an older catalog.json that
  // predates that field. Song titles that match directly are listed below
  // the artists. Modeled after Spotify's search dropdown, minus the
  // query-completion row and the Follow/+ actions, which don't apply here
  // (no accounts, no playlists).
  static const _maxSuggestions = 6;

  List<
      ({
        String label,
        bool isArtist,
        String thumbnailUrl,
        String? subtitleArtist,
      })> get _suggestions {
    final q = _searchQuery.toLowerCase().trim();
    if (q.isEmpty) return const [];

    final seenArtists = <String>{};
    final artistResults = <({
      String label,
      bool isArtist,
      String thumbnailUrl,
      String? subtitleArtist,
    })>[];
    final titleResults = <({
      String label,
      bool isArtist,
      String thumbnailUrl,
      String? subtitleArtist,
    })>[];

    for (final song in _catalog) {
      // Only test each artist once, on the song where we first see them —
      // whether the artist matches doesn't depend on which of their songs
      // we happened to check it against.
      if (seenArtists.add(song.artist) && song.artistMatches(q)) {
        artistResults.add((
          label: song.artist,
          isArtist: true,
          thumbnailUrl: song.artistAvatarUrl ?? song.thumbnailUrl,
          subtitleArtist: null,
        ));
      }
      if (song.title.toLowerCase().contains(q)) {
        titleResults.add((
          label: song.title,
          isArtist: false,
          thumbnailUrl: song.thumbnailUrl,
          subtitleArtist: song.artist,
        ));
      }
    }

    artistResults.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    titleResults.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );

    return [...artistResults, ...titleResults].take(_maxSuggestions).toList();
  }

  // Fills the search box with a tapped suggestion and dismisses the
  // dropdown — this then behaves exactly like typing that text yourself:
  // the main list below filters to matching songs.
  void _selectSuggestion(String label) {
    _searchController.text = label;
    _searchController.selection =
        TextSelection.collapsed(offset: label.length);
    setState(() => _searchQuery = label);
    _searchFocusNode.unfocus();
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
    final notificationGranted = await _overlayChannel
        .invokeMethod<bool>('hasNotificationPermission');
    setState(() {
      _hasPermission = granted ?? false;
      _hasNotificationPermission = notificationGranted ?? false;
    });
  }

  Future<void> _requestPermission() async {
    await _overlayChannel.invokeMethod('requestOverlayPermission');
  }

  Future<void> _requestNotificationPermission() async {
    await _overlayChannel.invokeMethod('requestNotificationPermission');
  }

  // When set, shuffling (including the auto-reshuffle that happens when a
  // shuffle pass runs out) is restricted to these catalog indices instead of
  // the whole catalog — this is what lets "Shuffle Play All" shuffle only
  // the current search results when a filter is active. Null means "the
  // whole catalog", which is also what tapping an individual track resets
  // it to, so browsing back to the full list after a scoped shuffle behaves
  // like a normal player again.
  List<int>? _shuffleScope;

  void _newShuffleOrder({int? startingWith}) {
    final pool = _shuffleScope ?? List.generate(_catalog.length, (i) => i);
    final indices = List<int>.from(pool)..shuffle();
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
    final song = _catalog[songIndex];
    await _overlayChannel.invokeMethod(
      'playVideo',
      {
        'videoId': song.videoId,
        // So the persistent notification can show the actual song/artist
        // instead of the generic "VSpo Music / Playing in the background".
        'title': song.title,
        'artist': song.artist,
      },
    );
  }

  Future<void> _shufflePlayAll() async {
    if (_hasPermission != true) {
      await _requestPermission();
      return;
    }
    // If a search filter is active, "Shuffle Play All" shuffles just the
    // matching songs (and keeps looping within just them, via _shuffleScope)
    // instead of the whole catalog.
    final filtered = _searchQuery.isEmpty ? null : _visibleIndices;
    if (filtered != null && filtered.isEmpty) return;
    _shuffleScope = filtered;
    _newShuffleOrder();
    await _playSongAt(0);
  }

  Future<void> _playSpecificSong(int songIndex) async {
    if (_hasPermission != true) {
      await _requestPermission();
      return;
    }
    // Tapping a specific track always plays/continues across the whole
    // catalog, regardless of any active search filter or prior scoped
    // shuffle — matches the pre-search behavior.
    _shuffleScope = null;
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
        (_currentSongIndex != null && _currentSongIndex! < _catalog.length)
            ? _catalog[_currentSongIndex!]
            : null;

    final visibleIndices = _visibleIndices;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildSearchBar()),
            if (_searchFocusNode.hasFocus &&
                _searchQuery.isNotEmpty &&
                _suggestions.isNotEmpty)
              SliverToBoxAdapter(child: _buildSuggestions(_suggestions)),
            SliverToBoxAdapter(
              child: _buildHeader(currentSong, visibleIndices.length),
            ),
            if (_hasPermission == false) SliverToBoxAdapter(child: _buildPermissionBanner()),
            if (_hasNotificationPermission == false)
              SliverToBoxAdapter(child: _buildNotificationPermissionBanner()),
            if (_searchQuery.isNotEmpty && visibleIndices.isEmpty)
              SliverToBoxAdapter(child: _buildNoResults())
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _buildTrackRow(visibleIndices[i]),
                  childCount: visibleIndices.length,
                  // Rows are stateless (no TextField/PageStorage/etc to
                  // preserve), so skip the extra keep-alive bookkeeping
                  // Flutter otherwise wraps around every list item.
                  addAutomaticKeepAlives: false,
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

  Widget _buildHeader(Song? currentSong, int visibleCount) {
    final searchActive = _searchQuery.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: AspectRatio(
              aspectRatio: 1,
              child: currentSong != null
                  ? Transform.scale(
                      // Crops the letterbox bars some thumbnails bake in —
                      // see _ThumbnailImage's doc comment. This one square
                      // is sized responsively (fills the screen width) so
                      // it can't reuse that fixed-size widget directly, but
                      // gets the same treatment by hand.
                      scale: _thumbnailZoomScale,
                      child: CachedNetworkImage(
                        imageUrl: currentSong.thumbnailUrl,
                        fit: BoxFit.cover,
                        // Decode straight to roughly the size this square is
                        // ever shown at (a couple hundred logical px, times a
                        // margin for high-DPI screens) instead of whatever
                        // huge resolution vspodex.app happens to serve —
                        // avoids paying full-res JPEG/WEBP decode cost for a
                        // small on-screen image.
                        memCacheWidth: 640,
                        fadeInDuration: const Duration(milliseconds: 120),
                        placeholder: (_, __) => _buildHeaderPlaceholder(),
                        // Falls back to the placeholder gradient+icon if the
                        // thumbnail fails to load (e.g. transient network
                        // hiccup), rather than showing a broken-image icon.
                        errorWidget: (_, __, ___) => _buildHeaderPlaceholder(),
                      ),
                    )
                  : _buildHeaderPlaceholder(),
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
            _loadingCatalog
                ? 'Loading catalog…'
                : 'Curated by vspodex.app · ${_catalog.length} songs',
            style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: (_loadingCatalog || (searchActive && visibleCount == 0))
                      ? null
                      : _shufflePlayAll,
                  icon: const Icon(Icons.shuffle),
                  label: Text(
                    _playing
                        ? 'Shuffling…'
                        : (searchActive
                            ? 'Shuffle These $visibleCount Songs'
                            : 'Shuffle Play All'),
                  ),
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

  // The "nothing playing yet" state for the header — the VSpo logo, on a
  // white backing (the logo artwork itself has a white background). Also
  // used as a fallback if a now-playing thumbnail fails to load.
  Widget _buildHeaderPlaceholder() {
    return Container(
      color: Colors.white,
      child: Image.asset(
        'assets/branding/vspo_logo.png',
        fit: BoxFit.contain,
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        onChanged: (value) => setState(() => _searchQuery = value),
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: 'Search songs or artists…',
          hintStyle: TextStyle(color: Colors.grey.shade500),
          prefixIcon: Icon(Icons.search, color: Colors.grey.shade500),
          suffixIcon: _searchQuery.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.clear, color: Colors.grey.shade500),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _searchQuery = '');
                  },
                ),
          filled: true,
          fillColor: const Color(0xFF1E1E1E),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  // The dropdown itself: an artist row per matching artist (circular
  // avatar + "Artist"), then a row per matching song title (16:9 video
  // thumbnail + "Song • Artist") — mirrors Spotify's search rows.
  Widget _buildSuggestions(
    List<
            ({
              String label,
              bool isArtist,
              String thumbnailUrl,
              String? subtitleArtist,
            })>
        suggestions,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in suggestions)
            InkWell(
              onTap: () => _selectSuggestion(s.label),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    // Circular 1:1 for an artist avatar (a real profile
                    // photo, already roughly square) vs. a 16:9 rectangle
                    // for a song thumbnail (an actual video thumbnail) —
                    // matching each source's real aspect ratio instead of
                    // cropping a video thumbnail down to a square.
                    _ThumbnailImage(
                      url: s.thumbnailUrl,
                      width: s.isArtist ? 40 : 57,
                      height: s.isArtist ? 40 : 32,
                      borderRadius: s.isArtist ? 20 : 4,
                      errorIcon: s.isArtist ? Icons.person : Icons.music_note,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            s.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            s.isArtist ? 'Artist' : 'Song • ${s.subtitleArtist}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.grey.shade500,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNoResults() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 8),
      child: Center(
        child: Text(
          'No songs match "$_searchQuery"',
          style: TextStyle(color: Colors.grey.shade500),
        ),
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

  Widget _buildNotificationPermissionBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.deepPurple.withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.notifications_off_outlined,
              color: Colors.deepPurpleAccent),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Allow notifications so you can see the playback notification '
              'and use its Stop button to fully stop the music.',
              style: TextStyle(fontSize: 12.5, color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: _requestNotificationPermission,
            child: const Text('Allow'),
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
      // 16:9 to match the actual video thumbnail's shape — a square here
      // would crop off ~44% of the width (this used to be size: 48, i.e.
      // square, which is what made these look squished/cropped).
      //
      // Also the single biggest fix for the list-scrolling jank: vspodex.app
      // thumbnails are often 1280x720+, and decoding that in full for every
      // one of ~340 rows just to show a small thumbnail (repeatedly, as rows
      // scroll in and out) is what was costing frames. _ThumbnailImage caps
      // the decode target to roughly the on-screen size, which keeps far
      // more thumbnails resident in the image cache at once — also less
      // re-decoding on every fling. Disk caching (built into
      // cached_network_image) also means these aren't re-downloaded from
      // scratch every time the app is reopened.
      leading: _ThumbnailImage(
        url: song.thumbnailUrl,
        width: 85,
        height: 48,
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
                    // 16:9, matching the video thumbnail's real shape —
                    // see the track-row thumbnail's comment for why.
                    _ThumbnailImage(
                      url: song.thumbnailUrl,
                      width: 78,
                      height: 44,
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
