part of 'main.dart';

// Feature 7: News. Three pieces:
// - "N new songs" popup on launch: songs in the catalog that this phone
//   hasn't announced yet (seen_songs.json on the device).
// - The side drawer: News, and Vspo (back to the main screen with the footer).
// - The News page: every update (assets/changelog.json) and every new song
//   (Song.addedAt), newest first, as same-size cards. Tapping a card opens
//   the details: an update's full change list ("details"), or the songs.
//
// changelog.json entries: {version?, date, notes, details?}. notes = the
// short summary (same text as whats-new.txt, which the update popup shows);
// details = every user-visible change, one line each.

// Live copy, so a new entry shows without an app update. Same repo as the
// catalog (see _remoteCatalogUrl).
const _remoteChangelogUrl =
    'https://raw.githubusercontent.com/soozyyy/VspoM/main/app/assets/changelog.json';

/// Update history, newest first: [{version?, date, notes}]. GitHub first,
/// then the copy bundled in the APK. Empty if both fail.
Future<List<Map<String, dynamic>>> _loadChangelog() async {
  List<Map<String, dynamic>> parse(String body) =>
      (jsonDecode(body) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .where((e) => e['date'] is String)
          .toList();
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 6);
  try {
    final request = await client
        .getUrl(Uri.parse(_remoteChangelogUrl))
        .timeout(const Duration(seconds: 6));
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode == 200) {
      return parse(await response.transform(utf8.decoder).join());
    }
  } catch (_) {
    // Offline or malformed — fall back to the bundled copy.
  } finally {
    client.close(force: true);
  }
  try {
    return parse(await rootBundle.loadString('assets/changelog.json'));
  } catch (_) {
    return [];
  }
}

Future<File> _seenSongsFile() async =>
    File('${(await getApplicationSupportDirectory()).path}/seen_songs.json');

/// videoIds this phone has already been told about. Null = no file yet
/// (first launch, or first launch since this feature shipped).
Future<Set<String>?> _loadSeenSongs() async {
  try {
    final file = await _seenSongsFile();
    if (!await file.exists()) return null;
    return Set<String>.from(jsonDecode(await file.readAsString()) as List);
  } catch (_) {
    return null;
  }
}

Future<void> _saveSeenSongs(Set<String> ids) async {
  try {
    await (await _seenSongsFile()).writeAsString(jsonEncode(ids.toList()));
  } catch (_) {
    // Worst case the same songs are announced again next launch.
  }
}

extension _News on _PlaylistScreenState {
  /// Once per launch, after the catalog is loaded and any update dialog is
  /// closed: shows songs the phone hasn't announced yet.
  Future<void> _showNewSongs() async {
    // Mock data would mark every real song as new on the next launch.
    if (_catalog.isEmpty || _catalog.first.videoId == _mockVideoId) return;
    final seen = await _loadSeenSongs();
    // Union, so a launch on an older cached catalog never forgets a song.
    await _saveSeenSongs({...?seen, for (final s in _catalog) s.videoId});
    // No file yet: everything counts as seen, or it would announce ~350 songs.
    if (seen == null || !mounted) return;
    final fresh = [
      for (var i = 0; i < _catalog.length; i++)
        if (!seen.contains(_catalog[i].videoId)) i,
    ];
    if (fresh.isEmpty) return;
    _showSongsDialog(fresh);
  }

  static String _songCount(int n) => n == 1 ? '1 new song' : '$n new songs';

  // The launch popup and a NEW SONGS card's details. Tap a song to play it.
  void _showSongsDialog(List<int> songs, {String? date}) {
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: _dialogTitle(_songCount(songs.length), date),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final i in songs)
                _buildTrackRow(i, onTap: () {
                  Navigator.of(c).pop();
                  _playSpecificSong(i);
                }),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // An UPDATE card's details: the summary, then every change.
  void _showUpdateDialog(Map<String, dynamic> e) {
    final details = (e['details'] as List<dynamic>? ?? []).whereType<String>();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: _dialogTitle(_updateTitle(e), e['date'] as String),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((e['notes'] as String? ?? '').trim()),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('All changes', style: Theme.of(c).textTheme.titleSmall),
                const SizedBox(height: 6),
                for (final d in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  '),
                        Expanded(child: Text(d)),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(c).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  static String _updateTitle(Map<String, dynamic> e) =>
      e['version'] is String ? 'Version ${e['version']}' : 'App update';

  static String _newsDate(String date) => date.replaceAll('-', '/');

  Widget _dialogTitle(String title, String? date) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          if (date != null)
            Text(
              _newsDate(date),
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
            ),
        ],
      );

  // ---- Side drawer ----

  // onNews: which page the drawer is on, so that item shows as selected.
  Widget _buildDrawer({required bool onNews}) {
    return NavigationDrawer(
      selectedIndex: onNews ? 0 : 1,
      onDestinationSelected: (i) {
        if (i == 0 && !onNews) {
          Navigator.of(context).pop(); // closes the drawer
          _pushLive(_buildNews);
        } else if (i == 1 && onNews) {
          Navigator.of(context).popUntil((r) => r.isFirst);
        } else {
          Navigator.of(context).pop();
        }
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('VspoM', style: Theme.of(context).textTheme.titleLarge),
              if (_appVersion != null)
                Text(
                  'v$_appVersion',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
                ),
            ],
          ),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.newspaper_outlined),
          selectedIcon: Icon(Icons.newspaper),
          label: Text('News'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music),
          label: Text('Vspo'),
        ),
      ],
    );
  }

  // ---- News page ----

  Widget _buildNews(BuildContext routeContext) {
    final songsByDate = <String, List<int>>{};
    for (var i = 0; i < _catalog.length; i++) {
      final d = _catalog[i].addedAt;
      if (d != null) (songsByDate[d] ??= []).add(i);
    }
    // (date, card), newest first.
    final cards = <(String, Widget)>[
      for (final e in _changelog)
        (
          e['date'] as String,
          _buildNewsCard(
            tag: 'UPDATE',
            tagColor: Colors.deepPurpleAccent,
            date: e['date'] as String,
            title: _updateTitle(e),
            preview: (e['notes'] as String? ?? '').trim(),
            onTap: () => _showUpdateDialog(e),
          ),
        ),
      for (final MapEntry(key: date, value: songs) in songsByDate.entries)
        (
          date,
          _buildNewsCard(
            tag: 'NEW SONGS',
            tagColor: Colors.teal,
            date: date,
            title: _songCount(songs.length),
            preview: songs.map((i) => _catalog[i].title).join(' · '),
            onTap: () => _showSongsDialog(songs, date: date),
          ),
        ),
    ]..sort((a, b) => b.$1.compareTo(a.$1));

    final song = _currentSong;
    return Scaffold(
      appBar: AppBar(title: const Text('News')),
      drawer: _buildDrawer(onNews: true),
      body: cards.isEmpty
          ? Center(
              child: Text('No news yet',
                  style: TextStyle(color: Colors.grey.shade500)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [for (final c in cards) c.$2],
            ),
      bottomNavigationBar: song == null ? null : _buildMiniPlayer(song),
    );
  }

  // Fixed height so every card is the same size; the preview is cut to two
  // lines and the full content is one tap away.
  Widget _buildNewsCard({
    required String tag,
    required Color tagColor,
    required String date,
    required String title,
    required String preview,
    required VoidCallback onTap,
  }) {
    return Card(
      color: const Color(0xFF1E1E1E),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 132,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: tagColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _newsDate(date),
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 12.5),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: Text(
                    preview,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade400, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
