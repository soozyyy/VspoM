part of 'main.dart';

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
  // song has actually started playing and the player reports it. Null means
  // "not known yet".
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
  // YouTube's own measured loudness for this upload, in dB relative to its
  // -14 LUFS reference — positive means louder than reference. Scraped once
  // per song by catalog-scraper/scrape.js straight out of the watch page
  // (YouTube measures every upload at ingest; nothing is downloaded or
  // analyzed on our side). Used to put every song out at the same level —
  // see level.dart. Null for a song added since the last scrape run.
  final double? loudnessDb;
  // Date the scraper first found this song (YYYY-MM-DD). Null for the
  // original catalog. Drives the app's News page; unused on the website.
  final String? addedAt;
  // Which side-drawer page the song belongs to: which file it came from.
  final AppPage page;

  const Song({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    this.artistSlug,
    this.duration,
    this.artistAvatarUrl,
    this.loudnessDb,
    this.addedAt,
    this.page = AppPage.vspo,
  });

  // Matches catalog.json as written by catalog-scraper/scrape.js:
  // { videoId, title, artistName, artistSlug, thumbnail, artistAvatarUrl }
  factory Song.fromJson(Map<String, dynamic> json,
      [AppPage page = AppPage.vspo]) {
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
      loudnessDb: (json['loudnessDb'] as num?)?.toDouble(),
      addedAt: json['addedAt'] as String?,
      page: page,
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

// catalog-scraper/scrape.js (VSPO!) and himehina.js (HIMEHINA) are run by
// hand on the maintainer's PC and the refreshed files are pushed to the repo
// (vspodex.app's Cloudflare check blocks cloud servers, so it can't run on
// GitHub Actions). These are those files' raw content: a plain JSON GET, no
// scraping happens in the browser. Update the org/repo/branch here if the
// repo ever moves.
const _remoteCatalogUrl =
    'https://raw.githubusercontent.com/soozyyy/VspoM/main/catalog-scraper/catalog.json';
const _remoteHimehinaUrl =
    'https://raw.githubusercontent.com/soozyyy/VspoM/main/catalog-scraper/himehina.json';

/// Both pages' songs in one list, VSPO! first. One list means the queue
/// (catalog indices) keeps working when you switch pages; each page shows
/// only its own songs (Song.page).
Future<List<Song>> _loadCatalog() async {
  final lists = await Future.wait([
    _loadSongList(_remoteCatalogUrl, 'catalog', AppPage.vspo),
    _loadSongList(_remoteHimehinaUrl, 'himehina', AppPage.himehina),
  ]);
  return [...(lists[0].isNotEmpty ? lists[0] : _mockCatalog()), ...lists[1]];
}

/// Loads one song list, freshest source first:
/// 1. Live fetch from GitHub (`url`) — picks up whatever the last pushed
///    scrape found, no site rebuild needed. Saved in the browser (under
///    `name`) on success.
/// 2. The last copy that live fetch saved, for a visit with no or slow
///    network. (3) can be much older.
/// 3. The copy bundled at build time as assets/`name`.json, for the very
///    first visit with no network.
/// Empty if all three fail (the caller falls back to mock data for VSPO!).
Future<List<Song>> _loadSongList(String url, String name, AppPage page) async {
  List<Song> parse(String body) => (jsonDecode(body) as List<dynamic>)
      .map((e) => Song.fromJson(e as Map<String, dynamic>, page))
      .toList();

  final body = await _fetchText(url);
  if (body != null) {
    try {
      final songs = parse(body);
      if (songs.isNotEmpty) {
        // Only a body that fully parsed is worth keeping. Each list is well
        // under localStorage's ~5 MB limit.
        _storeSet(name, body);
        return songs;
      }
    } catch (_) {
      // Malformed JSON: the cached and bundled fallbacks cover it.
    }
  }

  try {
    final cached = _storeGet(name);
    if (cached != null) {
      final songs = parse(cached);
      if (songs.isNotEmpty) return songs;
    }
  } catch (_) {
    // Fall through to the bundled copy.
  }

  try {
    return parse(await rootBundle.loadString('assets/$name.json'));
  } catch (_) {
    return [];
  }
}

// Placeholder catalog used until catalog.json has real entries — see
// _loadCatalog() above.
const _mockVideoId = 'dQw4w9WgXcQ';

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
      videoId: _mockVideoId,
      title: title,
      artist: artist,
      thumbnailUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg',
      duration: Duration(seconds: seconds),
    );
  });
}
