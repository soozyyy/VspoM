part of 'main.dart';

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

// catalog.json's thumbnails are YouTube's maxresdefault, which YouTube only
// generates for high-res uploads — 11 of 344 songs 404 on it (checked
// 2026-09-23), e.g. 空澄セナ's フォニイ. hqdefault exists for every video.
// It's 4:3 with the 16:9 frame letterboxed inside, and BoxFit.cover in a
// 16:9 box crops exactly those bars off. Null for anything that isn't a
// YouTube video thumbnail (artist avatars), or is already hqdefault.
String? _hqFallbackUrl(String url) {
  final id = RegExp(r'i\.ytimg\.com/vi(?:_webp)?/([^/]+)/')
      .firstMatch(url)
      ?.group(1);
  if (id == null || url.contains('/hqdefault.')) return null;
  return 'https://i.ytimg.com/vi/$id/hqdefault.jpg';
}

// errorBuilder for any thumbnail image: retry once with hqdefault, and only
// show `orElse` if that fails too.
Widget _thumbnailFallback(String url, Widget orElse) {
  final fallback = _hqFallbackUrl(url);
  if (fallback == null) return orElse;
  return _netImage(fallback, onError: () => orElse);
}

// Every network image on the site. Flutter can only draw an image itself
// when its host allows cross-site reads (CORS); for hosts that don't, the
// fallback strategy shows it as a plain browser <img> instead of failing.
// The placeholder sits behind the image until it loads. The browser's own
// cache replaces the app's disk cache (cached_network_image).
Widget _netImage(
  String url, {
  required Widget Function() onError,
  Widget? placeholder,
  int? cacheWidth,
}) {
  final image = Image.network(
    // Always hqdefault for YouTube video thumbnails: a missing maxresdefault
    // comes back as YouTube's grey "..." picture, which the <img> fallback
    // shows as if it loaded, so the error retry never runs.
    _hqFallbackUrl(url) ?? url,
    fit: BoxFit.cover,
    cacheWidth: cacheWidth,
    webHtmlElementStrategy: WebHtmlElementStrategy.fallback,
    errorBuilder: (_, _, _) => onError(),
  );
  if (placeholder == null) return image;
  return Stack(fit: StackFit.expand, children: [placeholder, image]);
}

// A network thumbnail with a shared placeholder/error look, used for
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
        child: _netImage(
          url,
          // Decode at roughly the on-screen size (x2 for high-DPI screens).
          cacheWidth: (width * 2).round(),
          placeholder: Container(color: Colors.grey.shade800),
          onError: () => _thumbnailFallback(
            url,
            Container(
              color: Colors.grey.shade800,
              child: Icon(
                errorIcon,
                color: Colors.white38,
                size: (width < height ? width : height) * 0.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Artist slugs (vspodex.app's, same as Song.artistSlug) in debut order,
// senpai -> kohai: the order of the Artists grid. JP first, then EN.
// Sources, checked 2026-09-23: vspo-oshikatublog.com/vspo-member-list and
// nushipedia.com/19224. Lists every member, including ones with no songs in
// the catalog yet, so they land in the right spot once they get some.
// A slug missing from both (a new debut) goes after the last listed member
// of its branch: EN if the artist name contains "VSPO! EN", else JP. To
// place a new member exactly, append their slug to the right list.
const _jpDebutOrder = [
  'vspo-official', // the group's own channel, not a member — kept first
  'kaga-sumire', 'kaga-nazuna', 'kogara-toto', 'ichinose-uruha',
  'kurumi-noah', 'tosaki-mimi', 'asumi-sena', 'tachibana-hinano',
  'hanabusa-lisa', 'kisaragi-ren', 'kaminari-qpi', 'yakumo-beni',
  'aizawa-ema', 'shinomiya-runa', 'nekota-tsuna', 'shiranami-ramune',
  'komori-met', 'yumeno-akari', 'yano-kuromu', 'tsumugi-kokage',
  'sendo-yuuhi', 'choya-hanabi', 'amayui-moka', 'ginjo-saine',
  'tatsumaki-chise',
];
const _enDebutOrder = [
  'remia-aotsuki', 'arya-kuroha', 'jira-jisaki', 'narin-mikure',
  'riko-solari', 'eris-suzukami', 'juno-umezono',
];

int _debutRank(Song song) {
  final slug = song.artistSlug ?? '';
  final jp = _jpDebutOrder.indexOf(slug);
  if (jp >= 0) return jp;
  final en = _enDebutOrder.indexOf(slug);
  if (en >= 0) return 1000 + en;
  return song.artist.contains('VSPO! EN') ? 2000 : 999;
}
