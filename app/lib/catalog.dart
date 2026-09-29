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
  // YouTube's own measured loudness for this upload, in dB relative to its
  // -14 LUFS reference — positive means louder than reference. Scraped once
  // per song by catalog-scraper/scrape.js straight out of the watch page
  // (YouTube measures every upload at ingest; nothing is downloaded or
  // analyzed on our side). Handed to the native player, which uses it to put
  // every song out at the same level instead of guessing from the first
  // second of audio — see OverlayService.injectionScript(). Null for a song
  // added to the catalog since the last scrape run; the player treats that
  // as "leave the level alone".
  final double? loudnessDb;

  const Song({
    required this.videoId,
    required this.title,
    required this.artist,
    required this.thumbnailUrl,
    this.artistSlug,
    this.duration,
    this.artistAvatarUrl,
    this.loudnessDb,
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
      loudnessDb: (json['loudnessDb'] as num?)?.toDouble(),
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

// catalog-scraper/scrape.js is run by hand on the maintainer's PC and the
// refreshed catalog.json is pushed to the repo (vspodex.app's Cloudflare
// check blocks cloud servers, so it can't run on GitHub Actions). This is
// that file's raw content: a plain JSON GET, no scraping happens on-device.
// Update the org/repo/branch here if the repo ever moves.
const _remoteCatalogUrl =
    'https://raw.githubusercontent.com/soozyyy/VspoM/main/catalog-scraper/catalog.json';

/// Loads the VSpo catalog, freshest source first:
/// 1. Live fetch from GitHub (_remoteCatalogUrl) — picks up whatever the
///    last pushed scrape found, no app rebuild needed. Saved to disk on
///    success (see _saveCachedCatalog).
/// 2. The last catalog that live fetch saved, for a launch with no or slow
///    network. Without this, such a launch fell straight to (3), which can
///    be much older — and an old copy without loudnessDb turns volume
///    leveling off for the whole session.
/// 3. The copy bundled at build time as assets/catalog.json, for the very
///    first launch with no network.
/// 4. Mock placeholder data, so the app still runs before any of these exist.
Future<List<Song>> _loadCatalog() async {
  final remote = await _fetchRemoteCatalog();
  if (remote != null && remote.isNotEmpty) return remote;

  final cached = await _loadCachedCatalog();
  if (cached != null && cached.isNotEmpty) return cached;

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
    final songs = decoded
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
    // Only a body that fully parsed is worth keeping. Not awaited: a slow
    // disk must never delay the song list.
    if (songs.isNotEmpty) _saveCachedCatalog(body);
    return songs;
  } catch (_) {
    // Offline, DNS failure, GitHub hiccup, malformed JSON, etc. — the
    // cached and bundled fallbacks in _loadCatalog() cover all of these.
    return null;
  } finally {
    client.close(force: true);
  }
}

Future<File> _cachedCatalogFile() async =>
    File('${(await getApplicationSupportDirectory()).path}/catalog.json');

Future<void> _saveCachedCatalog(String body) async {
  try {
    // Write-then-rename, so a crash mid-write can't leave a truncated file
    // that would then be the fallback.
    final file = await _cachedCatalogFile();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(body, flush: true);
    await tmp.rename(file.path);
  } catch (_) {
    // Caching is best-effort; the bundled asset is still there.
  }
}

Future<List<Song>?> _loadCachedCatalog() async {
  try {
    final file = await _cachedCatalogFile();
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    return decoded
        .map((e) => Song.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return null;
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
