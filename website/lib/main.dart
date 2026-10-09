import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'level.dart';

part 'catalog.dart';
part 'playlists.dart';
part 'web_bridge.dart';
part 'widgets.dart';

// ---------------------------------------------------------------------------
// VspoM website — entry point and the main screen. The PC browser version of
// the app: a separate copy of app/lib, changed freely without touching the
// app. App features are ported here by hand when they fit.
//
// Differences from the app:
//   - Playback is YouTube's IFrame player (web/player.js, reached through
//     web_bridge.dart) instead of OverlayService.kt. All sequencing (shuffle,
//     next, queue) is the same Dart code as the app.
//   - Storage is the browser's localStorage instead of files.
//   - No updater, permissions, News page or new-songs popup.
//   - PC layout: a left rail (Library · Queue · Playlists) instead of the
//     footer tabs, a player bar along the bottom with a volume slider,
//     content capped at a readable width, Space = play/pause.
//   - Songs YouTube won't play on other sites are skipped with a notice.
// The side drawer (☰ at the top of the rail) switches between two pages,
// VSPO! and HIMEHINA (AppPage), same as the app: each has its own song list,
// playlists and accent colour; both song lists live in one _catalog
// (Song.page), so the queue keeps playing across a switch.
//
//   catalog.dart     Song model + loading catalog.json
//                    (remote -> browser cache -> bundled -> mock)
//   widgets.dart     images/thumbnails + the Artists debut order
//   playlists.dart   the Playlists tab + its pages
//   web_bridge.dart  Dart handles for web/player.js
//   level.dart       volume leveling (a separate library, so it's testable)
// Imports live here only; part files can't have their own.
// ---------------------------------------------------------------------------

enum AppPage { vspo, himehina }

// The page the side drawer is on, remembered in this browser.
final _page = ValueNotifier<AppPage>(
    _storeGet('page') == 'himehina' ? AppPage.himehina : AppPage.vspo);

void main() {
  runApp(const VspoMusicApp());
}

// Official colours, read from vspo.jp and himehina.jp (2026-10-09). VSPO!'s
// main colour is a pink almost identical to HimeHina's, so the VSPO! page
// uses its official second colour, purple. HIMEHINA: Hime's pink, with
// Hina's blue as a small second accent (the seek-bar knob, the gradient
// behind the header before anything plays).
ThemeData _themeFor(AppPage page) {
  final himehina = page == AppPage.himehina;
  final accent = himehina ? const Color(0xFFFD5D8A) : const Color(0xFF7264D0);
  final scheme =
      ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark)
          .copyWith(
    primary: accent,
    onPrimary: himehina ? Colors.black : Colors.white,
    secondary: himehina ? const Color(0xFF3EB8FC) : accent,
    onSecondary: himehina ? Colors.black : Colors.white,
  );
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF121212),
    useMaterial3: true,
  );
}

class VspoMusicApp extends StatelessWidget {
  const VspoMusicApp({super.key});

  @override
  Widget build(BuildContext context) {
    // A page switch swaps the theme (MaterialApp fades between them). The
    // home screen is const, so its state (queue, search) survives.
    return ValueListenableBuilder<AppPage>(
      valueListenable: _page,
      builder: (_, page, _) => MaterialApp(
        title: 'VspoM',
        debugShowCheckedModeBanner: false,
        theme: _themeFor(page),
        home: const PlaylistScreen(),
      ),
    );
  }
}

class PlaylistScreen extends StatefulWidget {
  const PlaylistScreen({super.key});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<Song> _catalog = [];
  bool _loadingCatalog = true;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _libraryScroll = ScrollController();
  String _searchQuery = '';
  List<int> _playOrder = [];
  int _playOrderIndex = 0;
  int? _currentSongIndex;
  bool _playing = false;
  bool _isPaused = false;

  // Playlists (playlists.dart). _tab is the left rail's tab: 0 Library,
  // 1 Queue (Now Playing), 2 Playlists. _inOrder means _playOrder is a
  // playlist played in order, so running off the end restarts it instead of
  // reshuffling.
  List<Playlist> _playlists = [];
  bool _playlistsLoaded = false;
  int _tab = 0;
  bool _inOrder = false;

  // The listener's volume (0..1), from the player bar's slider. Remembered
  // in this browser. Multiplied by each song's leveling (level.dart).
  double _volume = double.tryParse(_storeGet('volume') ?? '') ?? 1.0;

  // Unplayable songs skipped in a row (see _skipUnplayable). After
  // _maxFailedInARow, playback stops instead of running through the catalog.
  static const _maxFailedInARow = 5;
  int _failedInARow = 0;
  bool _stalled = false;

  // The one way to change _playlists: repaints and saves to the browser.
  void _editPlaylists(VoidCallback fn) {
    setState(fn);
    _queueSavePlaylists(_playlists);
  }

  // Progress-bar state, refreshed by polling the player.
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _dragValueSeconds; // non-null while the user is actively dragging
  Timer? _progressTimer;
  bool _autoAdvancing = false;

  // Bumped on every setState (see override below). The full-screen Now
  // Playing page is a pushed route, and a route's builder doesn't re-run
  // when this State calls setState — so it listens to this instead and
  // rebuilds off the same fields the mini-player reads.
  final _changes = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _changes.value++;
  }

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    // Repaints so the suggestions dropdown appears/disappears as the search
    // field gains/loses focus (see _suggestions / _buildSuggestions below).
    _searchFocusNode.addListener(() => setState(() {}));
    _loadCatalog().then((songs) {
      if (!mounted) return;
      setState(() {
        _catalog = songs;
        _loadingCatalog = false;
      });
    });
    _loadPlaylists().then((lists) {
      if (!mounted) return;
      setState(() {
        _playlists = lists;
        _playlistsLoaded = true;
      });
    });
    _progressTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollPosition(),
    );
  }

  // Space = play/pause, except while typing in a text field.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.space ||
        _currentSongIndex == null) {
      return false;
    }
    final typing = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    if (typing) return false;
    _togglePlayPause();
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _progressTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _libraryScroll.dispose();
    _changes.dispose();
    super.dispose();
  }

  // Original-catalog indices whose song matches the current search query, in
  // catalog order. Kept as (originalIndex, song) pairs so tapping a filtered
  // row, and highlighting the currently-playing row, still refer back to the
  // right index in _catalog (shuffle order is also built from _catalog
  // indices, so this doesn't disturb playback).
  // Only the current page's songs.
  List<int> get _visibleIndices => [
        for (final i in _pageIndices(_page.value))
          if (_catalog[i].matchesSearch(_searchQuery)) i,
      ];

  // Catalog indices of one page's songs, in catalog order.
  List<int> _pageIndices(AppPage page) => [
        for (var i = 0; i < _catalog.length; i++)
          if (_catalog[i].page == page) i,
      ];

  // Called by the side drawer. The queue keeps playing; the library starts
  // fresh (no leftover search, back at the top).
  void _switchPage(AppPage page) {
    if (page == _page.value) return;
    _searchController.clear();
    _searchFocusNode.unfocus();
    if (_libraryScroll.hasClients) _libraryScroll.jumpTo(0);
    _page.value = page; // swaps the theme (VspoMusicApp listens)
    _storeSet('page', page.name);
    setState(() => _searchQuery = '');
  }

  // Autocomplete rows shown under the search bar while typing — e.g. typing
  // "su" surfaces the artist Sumire, using her real profile picture when
  // catalog.json has one (artistAvatarUrl — vspodex.app's own artist page,
  // scraped once per artist; usually their YouTube channel avatar), falling
  // back to one of her song thumbnails for an older catalog.json that
  // predates that field. Song titles that match directly are listed below
  // the artists. Modeled after Spotify's search dropdown, minus the
  // query-completion row and the Follow/+ actions, which don't apply here
  // (no accounts).
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
      if (song.page != _page.value) continue;
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
    _nextOrder = null;
  }

  // The loop after this one, previewed under Up Next. In order it's just the
  // same order again. Shuffled, it's picked ahead of time (not when the last
  // song ends) so the preview is exactly what will play.
  List<int>? _nextOrder;
  List<int> get _nextLoop {
    if (_inOrder) return _playOrder;
    return _nextOrder ??= List<int>.from(
        _shuffleScope ?? List.generate(_catalog.length, (i) => i))
      ..shuffle();
  }

  Future<void> _playSongAt(int orderIndex) async {
    if (_playOrder.isEmpty) return;
    if (orderIndex < 0) return;
    if (orderIndex >= _playOrder.length) {
      // Reached the end of the list — reshuffle and loop forever, or, for a
      // playlist played in order, start the same order over.
      if (!_inOrder) {
        _playOrder = _nextLoop;
        _nextOrder = null;
      }
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
    _failedInARow = 0;
    _stalled = false;
    final song = _catalog[songIndex];
    _jsPlay(song.videoId, _playerVolume(song));
  }

  // 0..100 for the player: the listener's volume times this song's leveling.
  double _playerVolume(Song song) =>
      100 * _volume * levelFactor(song.loudnessDb);

  void _setVolume(double v) {
    setState(() => _volume = v);
    _storeSet('volume', '$v');
    final song = _currentSong;
    if (song != null) _jsSetVolume(_playerVolume(song));
  }

  // Some uploads can't be played outside youtube.com (the uploader blocked
  // it: errors 101/150) or are gone (100). Skip to the next song with a
  // notice — but after a run of failures stop instead, so a network outage
  // doesn't spin through the whole catalog. Play then retries the same song.
  Future<void> _skipUnplayable() async {
    final song = _currentSong;
    if (song == null || _autoAdvancing || _stalled) return;
    final failed = _failedInARow + 1;
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    if (failed >= _maxFailedInARow) {
      setState(() {
        _stalled = true;
        _isPaused = true;
      });
      messenger.showSnackBar(const SnackBar(
        content: Text("Couldn't play $_maxFailedInARow songs in a row. "
            'Check your connection, then press play.'),
      ));
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(
          '"${song.title}" can\'t be played on the website. Skipping.'),
    ));
    _autoAdvancing = true;
    await _next();
    _failedInARow = failed; // _playSongAt reset it
    _autoAdvancing = false;
  }

  Future<void> _shufflePlayAll({List<int>? scope}) async {
    // "Shuffle Play All" shuffles this page's songs, or just the ones
    // matching the search (and keeps looping within them, via
    // _shuffleScope). The artist and playlist pages pass their own scope.
    final filtered = scope ?? _visibleIndices;
    if (filtered.isEmpty) return;
    _shuffleScope = filtered;
    _inOrder = false;
    _newShuffleOrder();
    await _playSongAt(0);
  }

  Future<void> _playSpecificSong(int songIndex) async {
    // Tapping a specific track always plays/continues across all of its
    // page's songs, regardless of any active search filter or prior scoped
    // shuffle — matches the pre-search behavior.
    _shuffleScope = _pageIndices(_catalog[songIndex].page);
    _inOrder = false;
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
    if (_stalled) return _playSongAt(_playOrderIndex);
    if (_isPaused) {
      _jsResume();
    } else {
      _jsPause();
    }
    setState(() => _isPaused = !_isPaused);
  }

  Future<void> _seekTo(Duration target) async {
    _jsSeek(target.inMilliseconds / 1000.0);
    setState(() {
      _position = target;
      _dragValueSeconds = null;
    });
  }

  Future<void> _pollPosition() async {
    if (_currentSongIndex == null || _dragValueSeconds != null || _stalled) {
      return;
    }
    final Map<String, dynamic> info;
    try {
      info = jsonDecode(_jsState()) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (info['error'] != null) return _skipUnplayable();

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

    // Auto-advance once the song ends, so shuffle keeps going (and loops via
    // _playSongAt's wraparound). Uses YouTube's own "ended" state rather
    // than the app's position-near-duration check: during an ad, position
    // and duration are the ad's.
    if (info['ended'] == true && !_autoAdvancing) {
      _autoAdvancing = true;
      await _next();
      _autoAdvancing = false;
    }
  }

  Song? get _currentSong =>
      (_currentSongIndex != null && _currentSongIndex! < _catalog.length)
          ? _catalog[_currentSongIndex!]
          : null;

  @override
  Widget build(BuildContext context) {
    final currentSong = _currentSong;

    final visibleIndices = _visibleIndices;

    return Scaffold(
      drawer: _buildDrawer(),
      body: Row(
        children: [
          // The app's footer tabs, as a PC-style left rail.
          NavigationRail(
            selectedIndex: _tab,
            labelType: NavigationRailLabelType.all,
            // Builder: Scaffold.of needs a context below the Scaffold.
            leading: Builder(
              builder: (c) => IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'Menu',
                onPressed: () => Scaffold.of(c).openDrawer(),
              ),
            ),
            onDestinationSelected: (i) {
              _searchFocusNode.unfocus();
              setState(() => _tab = i);
            },
            destinations: [
              const NavigationRailDestination(
                icon: Icon(Icons.library_music_outlined),
                selectedIcon: Icon(Icons.library_music),
                label: Text('Library'),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.playlist_play),
                label: const Text('Queue'),
                // Now Playing needs a current song.
                disabled: currentSong == null,
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: Text('Playlists'),
              ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            // IndexedStack keeps the Library tab (scroll, search) alive while
            // another tab is showing.
            child: IndexedStack(
              index: _tab,
              children: [
                _pcWidth(
                  CustomScrollView(
                    controller: _libraryScroll,
                    slivers: [
                      SliverToBoxAdapter(child: _buildSearchBar()),
                      if (_searchFocusNode.hasFocus &&
                          _searchQuery.isNotEmpty &&
                          _suggestions.isNotEmpty)
                        SliverToBoxAdapter(
                            child: _buildSuggestions(_suggestions)),
                      SliverToBoxAdapter(
                        // The big square only shows a song from this page;
                        // otherwise it keeps the page's own logo.
                        child: _buildHeader(
                          currentSong?.page == _page.value
                              ? currentSong
                              : null,
                          visibleIndices.length,
                        ),
                      ),
                      if (_searchQuery.isNotEmpty && visibleIndices.isEmpty)
                        SliverToBoxAdapter(child: _buildNoResults())
                      else
                        SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, i) => _buildTrackRow(visibleIndices[i]),
                            childCount: visibleIndices.length,
                            // Rows are stateless, so skip the keep-alive
                            // bookkeeping Flutter otherwise adds per item.
                            addAutomaticKeepAlives: false,
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 24)),
                    ],
                  ),
                ),
                // Only built while showing: IndexedStack builds every child,
                // and this one would otherwise rebuild its rows on every
                // 500 ms poll in the background.
                _tab == 1 && currentSong != null
                    ? _buildNowPlaying()
                    : const SizedBox.shrink(),
                _pcWidth(_buildPlaylistsTab()),
              ],
            ),
          ),
        ],
      ),
      // Always shown once something plays (PC players keep it on every
      // page), since it also holds the volume slider.
      bottomNavigationBar:
          currentSong == null ? null : _buildMiniPlayer(currentSong),
    );
  }

  // Content width cap, so rows and headers don't stretch across a wide
  // monitor.
  static const _maxContentWidth = 1000.0;

  Widget _pcWidth(Widget child) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxContentWidth),
          child: child,
        ),
      );

  // The site's pages: 0 VSPO!, 1 HIMEHINA (AppPage order).
  Widget _buildDrawer() {
    return NavigationDrawer(
      selectedIndex: _page.value.index,
      onDestinationSelected: (i) {
        Navigator.of(context).pop(); // closes the drawer
        _switchPage(AppPage.values[i]);
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 16, 16),
          child: Text('VspoM', style: Theme.of(context).textTheme.titleLarge),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music),
          label: Text('VSPO!'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.favorite_outline),
          selectedIcon: Icon(Icons.favorite),
          label: Text('HIMEHINA'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 16, 16),
          child: Text(
            'Unofficial fan project. VSPO! songs curated by vspodex.app; '
            'HIMEHINA songs from their YouTube channel.',
            style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(Song? currentSong, int visibleCount) {
    final searchActive = _searchQuery.isNotEmpty;
    final himehina = _page.value == AppPage.himehina;
    final pageSongs = _pageIndices(_page.value).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: 200,
              child: currentSong != null
                  ? Transform.scale(
                      // Crops the letterbox bars of a 16:9 thumbnail shown
                      // in a square (see _thumbnailZoomScale).
                      scale: _thumbnailZoomScale,
                      child: _netImage(
                        currentSong.thumbnailUrl,
                        cacheWidth: 640,
                        placeholder: _buildHeaderPlaceholder(),
                        onError: () => _thumbnailFallback(
                          currentSong.thumbnailUrl,
                          _buildHeaderPlaceholder(),
                        ),
                      ),
                    )
                  : _buildHeaderPlaceholder(),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  himehina ? 'HIMEHINA' : 'VSPO!',
                  style: const TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _loadingCatalog
                      ? 'Loading catalog…'
                      : himehina
                          ? 'From the HIMEHINA YouTube channel · '
                              '$pageSongs songs'
                          : 'Curated by vspodex.app · $pageSongs songs',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 13),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: (_loadingCatalog ||
                              (searchActive && visibleCount == 0))
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
                        padding: const EdgeInsets.symmetric(
                          vertical: 16,
                          horizontal: 24,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _loadingCatalog ? null : _openArtists,
                      icon: const Icon(Icons.people_outline),
                      label: const Text('Artists'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: 16,
                          horizontal: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // The "nothing playing yet" state for the header — the VSpo logo, on a
  // white backing (the logo artwork itself has a white background). Also
  // used as a fallback if a now-playing thumbnail fails to load. HIMEHINA:
  // their handwritten signature (white, from himehina.jp's footer logo) on a
  // Hime-pink to Hina-blue gradient.
  Widget _buildHeaderPlaceholder() {
    if (_page.value == AppPage.himehina) {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [scheme.primary, scheme.secondary],
          ),
        ),
        child: Center(
          child: FractionallySizedBox(
            widthFactor: 0.8,
            child: Image.asset('assets/branding/himehina_signature.png'),
          ),
        ),
      );
    }
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
      child: Row(
        children: [
          Expanded(
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
          ),
        ],
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

  // onTap defaults to "start a new shuffle from this song" (library list);
  // the Up Next list passes its own to jump within the current order.
  // trailing: the playlist pages' add/remove/drag buttons.
  // highlight: purple title if this is the playing song. Off on Now Playing,
  // where the same song can reappear in the next-loop preview.
  // tappable: off for the next-loop preview, which is view-only.
  Widget _buildTrackRow(int index,
      {VoidCallback? onTap,
      Widget? trailing,
      bool highlight = true,
      bool tappable = true}) {
    final song = _catalog[index];
    final isCurrent = highlight && _currentSongIndex == index;
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
          color: isCurrent
              ? Theme.of(context).colorScheme.primary
              : Colors.white,
          fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: Colors.grey.shade400, fontSize: 12.5),
      ),
      trailing: trailing,
      onTap: tappable ? onTap ?? () => _playSpecificSong(index) : null,
    );
  }

  // The player bar along the bottom: song on the left (click it for Now
  // Playing), controls and seek bar in the middle, volume on the right.
  Widget _buildMiniPlayer(Song song) {
    final labelStyle = TextStyle(color: Colors.grey.shade400, fontSize: 12);
    return Material(
      color: const Color(0xFF1E1E1E),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: InkWell(
                onTap: _openNowPlaying,
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      // 16:9, matching the video thumbnail's real shape.
                      _ThumbnailImage(
                        url: song.thumbnailUrl,
                        width: 92,
                        height: 52,
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
                                  color: Colors.white, fontSize: 14),
                            ),
                            Text(
                              song.artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: Colors.grey.shade400, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 4,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.skip_previous,
                            color: Colors.white),
                        tooltip: 'Previous',
                        onPressed: _previous,
                      ),
                      IconButton(
                        icon: Icon(
                          _isPaused
                              ? Icons.play_circle_fill
                              : Icons.pause_circle_filled,
                          color: Colors.white,
                          size: 36,
                        ),
                        tooltip: _isPaused ? 'Play (Space)' : 'Pause (Space)',
                        onPressed: _togglePlayPause,
                      ),
                      IconButton(
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                        tooltip: 'Next',
                        onPressed: _next,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Text(_fmt(_shownPosition), style: labelStyle),
                      Expanded(child: _buildSeekBar()),
                      Text(
                        _duration > Duration.zero ? _fmt(_duration) : '--:--',
                        style: labelStyle,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Icon(
                    _volume == 0
                        ? Icons.volume_off
                        : (_volume < 0.5 ? Icons.volume_down : Icons.volume_up),
                    color: Colors.grey.shade400,
                  ),
                  // Fixed height: a Slider fills all the height it's given,
                  // and in this Row that was the whole screen.
                  SizedBox(
                    width: 130,
                    height: 40,
                    child: Slider(
                      value: _volume,
                      onChanged: _setVolume,
                      activeColor: Colors.white,
                      inactiveColor: Colors.grey.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Where the seek bar shows: the drag position while dragging.
  Duration get _shownPosition => _dragValueSeconds != null
      ? Duration(milliseconds: (_dragValueSeconds! * 1000).round())
      : _position;

  // Shared by the mini-player (thin, no labels) and the Now Playing page
  // (thicker, with elapsed/total time underneath).
  Widget _buildSeekBar({bool large = false}) {
    final durationMs = _duration.inMilliseconds;
    final sliderMax = durationMs > 0 ? durationMs.toDouble() : 1.0;
    final sliderValue = (_dragValueSeconds != null
            ? _dragValueSeconds! * 1000
            : _position.inMilliseconds.toDouble())
        .clamp(0.0, sliderMax);

    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: large ? 4 : 2.5,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: large ? 7 : 5),
        overlayShape: RoundSliderOverlayShape(overlayRadius: large ? 16 : 12),
        activeTrackColor: Theme.of(context).colorScheme.primary,
        inactiveTrackColor: Colors.grey.shade700,
        thumbColor: Theme.of(context).colorScheme.secondary,
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
    );
    if (!large) return slider;

    final labelStyle = TextStyle(color: Colors.grey.shade400, fontSize: 12);
    return Column(
      children: [
        slider,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_fmt(Duration(milliseconds: sliderValue.round())),
                  style: labelStyle),
              Text(durationMs > 0 ? _fmt(_duration) : '--:--',
                  style: labelStyle),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  // Pushes a full-screen page that rebuilds whenever this State does (see
  // _changes), so it always shows live playback state.
  void _pushLive(Widget Function(BuildContext routeContext) build) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: _changes,
        builder: (routeContext, _, _) => build(routeContext),
      ),
    ));
  }

  // Now Playing is the Queue tab. From an artist/playlist page (mini-player
  // tap) this closes those pages first.
  void _openNowPlaying() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    setState(() => _tab = 1);
  }

  void _openArtists() => _pushLive(_buildArtists);

  // Full-screen view of the same playback state the mini-player shows, plus
  // the rest of the current pass as "Up Next" (_playOrder after
  // _playOrderIndex) and a preview of the next loop (_nextLoop).
  // Shows at most this many songs in total, so shuffling the whole catalog
  // doesn't build a 650-row list.
  static const _maxQueueRows = 50;

  Widget _buildNowPlaying() {
    final song = _catalog[_currentSongIndex!];
    final upNextStart = _playOrderIndex + 1;
    final upNext = _playOrder.sublist(upNextStart);
    final nowRows = min(upNext.length, _maxQueueRows);
    // The next loop only shows once the current pass fits under the cap.
    final loopShown = upNext.length < _maxQueueRows;
    final loop = loopShown ? _nextLoop : const <int>[];
    final loopRows = min(loop.length, _maxQueueRows - nowRows);
    final hidden =
        loopShown ? loop.length - loopRows : upNext.length - nowRows;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        // It's a tab now, so no back/down arrow.
        automaticallyImplyLeading: false,
        title: const Text('Now Playing', style: TextStyle(fontSize: 15)),
        centerTitle: true,
      ),
      body: _pcWidth(CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 16:9, the thumbnail's real shape — no crop. Capped so
                  // it doesn't fill a whole monitor.
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: _netImage(
                            song.thumbnailUrl,
                            cacheWidth: 1280,
                            placeholder: Container(color: Colors.grey.shade800),
                            onError: () => _thumbnailFallback(
                              song.thumbnailUrl,
                              _buildHeaderPlaceholder(),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    song.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(child: _buildSeekBar(large: true)),
          SliverToBoxAdapter(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 40,
                  icon: const Icon(Icons.skip_previous, color: Colors.white),
                  onPressed: _previous,
                ),
                const SizedBox(width: 16),
                IconButton(
                  iconSize: 72,
                  icon: Icon(
                    _isPaused
                        ? Icons.play_circle_fill
                        : Icons.pause_circle_filled,
                    color: Colors.white,
                  ),
                  onPressed: _togglePlayPause,
                ),
                const SizedBox(width: 16),
                IconButton(
                  iconSize: 40,
                  icon: const Icon(Icons.skip_next, color: Colors.white),
                  onPressed: _next,
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
              child: Text(
                'Up Next · ${upNext.length}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              // Jumps straight to that position, YouTube Music style:
              // songs in between are skipped, so Previous walks back
              // through them rather than to the song you left.
              (context, i) => _buildTrackRow(
                upNext[i],
                highlight: false,
                onTap: () => _playSongAt(upNextStart + i),
                // Drops it from this pass only: the next reshuffle pulls
                // from the full scope again.
                trailing: IconButton(
                  icon: Icon(Icons.close, color: Colors.grey.shade500),
                  tooltip: 'Remove from queue',
                  onPressed: () => setState(
                    () => _playOrder.removeAt(upNextStart + i),
                  ),
                ),
              ),
              childCount: nowRows,
              addAutomaticKeepAlives: false,
            ),
          ),
          if (loopShown) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Row(
                  children: [
                    Icon(Icons.repeat, size: 16, color: Colors.grey.shade500),
                    const SizedBox(width: 8),
                    Text(
                      _inOrder
                          ? 'Then the playlist starts over'
                          : 'Then it reshuffles',
                      style: TextStyle(color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
            ),
            // View-only until that loop actually starts: no tap, no remove
            // (in order, this list is the playlist itself, including songs
            // already played).
            SliverList(
              delegate: SliverChildBuilderDelegate(
                // Dimmed so it reads as "not yet", not as a tappable list.
                (context, i) => Opacity(
                  opacity: 0.5,
                  child: _buildTrackRow(
                    loop[i],
                    highlight: false,
                    tappable: false,
                  ),
                ),
                childCount: loopRows,
                addAutomaticKeepAlives: false,
              ),
            ),
          ],
          if (hidden > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  '+ $hidden more',
                  style: TextStyle(color: Colors.grey.shade500),
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      )),
    );
  }

  // Every artist on the current page with their songs' catalog indices, in
  // debut order (see _debutRank). Grouped by display name, same as
  // _suggestions.
  List<MapEntry<String, List<int>>> get _artists {
    final byArtist = <String, List<int>>{};
    for (final i in _pageIndices(_page.value)) {
      byArtist.putIfAbsent(_catalog[i].artist, () => []).add(i);
    }
    return byArtist.entries.toList()
      ..sort((a, b) {
        final byDebut = _debutRank(_catalog[a.value.first])
            .compareTo(_debutRank(_catalog[b.value.first]));
        return byDebut != 0 ? byDebut : a.key.compareTo(b.key);
      });
  }

  Widget _buildArtists(BuildContext routeContext) {
    final artists = _artists;
    final song = _currentSong;
    return Scaffold(
      appBar: AppBar(title: const Text('Artists')),
      body: _pcWidth(GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 160,
          mainAxisExtent: 168,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: artists.length,
        itemBuilder: (context, i) {
          final name = artists[i].key;
          final indices = artists[i].value;
          final first = _catalog[indices.first];
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _pushLive((c) => _buildArtist(c, name)),
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                children: [
                  _ThumbnailImage(
                    url: first.artistAvatarUrl ?? first.thumbnailUrl,
                    width: 88,
                    height: 88,
                    borderRadius: 44,
                    errorIcon: Icons.person,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  ),
                  Text(
                    '${indices.length} songs',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
      )),
      bottomNavigationBar: song == null ? null : _buildMiniPlayer(song),
    );
  }

  // One artist's songs, matched on the exact artist name (not search, which
  // would also pull in other artists' songs that mention them in the title).
  Widget _buildArtist(BuildContext routeContext, String name) {
    final indices = [
      for (var i = 0; i < _catalog.length; i++)
        if (_catalog[i].artist == name) i,
    ];
    final first = _catalog[indices.first];
    final song = _currentSong;
    return Scaffold(
      appBar: AppBar(),
      body: _pcWidth(CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Column(
                children: [
                  _ThumbnailImage(
                    url: first.artistAvatarUrl ?? first.thumbnailUrl,
                    width: 140,
                    height: 140,
                    borderRadius: 70,
                    errorIcon: Icons.person,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    name,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 320,
                    child: FilledButton.icon(
                      // Scoped shuffle: loops within just this artist.
                      onPressed: () => _shufflePlayAll(scope: indices),
                      icon: const Icon(Icons.shuffle),
                      label: Text('Shuffle ${indices.length} songs'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _buildTrackRow(indices[i]),
              childCount: indices.length,
              addAutomaticKeepAlives: false,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      )),
      bottomNavigationBar: song == null ? null : _buildMiniPlayer(song),
    );
  }
}
