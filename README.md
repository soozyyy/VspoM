# VSpo Music App

Personal, single-user Android app for listening to VSpo! member music (sourced from YouTube, catalog curated by vspodex.app's `/music` page) in the background, like Spotify — screen off, other apps open, one screen, shuffle-play-all with continuous looping.

No server, no backend, no ongoing cost, nothing needs to run on a home PC. The catalog refreshes itself via a free GitHub Actions schedule; the app itself just plays music.

## How playback actually works

YouTube's web player renders video into an Android `SurfaceView`, and Android tears that Surface down (killing the video decoder, and the audio riding the same codec pipeline) the instant the hosting Activity's window stops being visible — so a normal in-app WebView player dies the moment you background the app or turn the screen off. That ruled out every "just embed a WebView" approach.

The fix: `OverlayService` (`app/android/.../OverlayService.kt`) runs as a foreground `Service` and adds a plain `android.webkit.WebView` directly to the `WindowManager` as an invisible 1x1 `TYPE_APPLICATION_OVERLAY` window — a system-level window with no relationship to the app's own Activity window. Backgrounding, closing, or switching away from the app has zero effect on it, so its video Surface (and the audio track riding it) never gets torn down. This is the same mechanism real background-audio apps rely on.

This requires the user to grant "Draw over other apps" (`SYSTEM_ALERT_WINDOW`) once, and — since Android 13 — notification permission (`POST_NOTIFICATIONS`), so the persistent playback notification (with its Stop button) actually shows up. The app prompts for both with in-app banners on first run.

Flutter talks to this native layer through a single `MethodChannel` (`vspo_music/overlay`): `playVideo`, `pause`, `resume`, `seek`, `getPosition`, `stop`, plus the two permission checks. No `just_audio`, `audio_service`, or `youtube_explode_dart` — playback is 100% native Android, driven from Dart.

## Project layout

```
VspoM/
  README.md
  .github/workflows/refresh-catalog.yml   # scheduled + manual catalog refresh (see below)
  catalog-scraper/
    package.json
    scrape.js        # Playwright scraper against vspodex.app's public /music page
    catalog.json      # generated output, kept in sync by the workflow above
  app/                # Flutter project (created via `flutter create app`)
    lib/main.dart      # the whole UI + playback control logic
    android/app/src/main/kotlin/.../
      MainActivity.kt   # MethodChannel handler
      OverlayService.kt # the background-playback engine (see above)
    assets/catalog.json # bundled fallback copy, used offline / before first successful fetch
```

## Keeping the catalog in sync with vspodex.app

vspodex.app has no public JSON API (it's a Next.js Server Actions app, and `/api` is explicitly disallowed by its `robots.txt` anyway) — `/music` itself is allowed, so `catalog-scraper/scrape.js` reads that rendered page with a headless browser instead.

One quirk that shaped the whole design: `/music` doesn't serve a stable, complete list — every page load (and every refresh) returns a random ~60-80 track sample of the full catalog, and scrolling only reveals more of that same sample, not the rest. So the scraper does several fresh-page-load passes in one run (`PASS_COUNT`, default 10) and merges everything it finds — deduped by YouTube video ID — into whatever `catalog.json` already exists, rather than overwriting it. Coverage climbs with more passes, with the usual diminishing returns near the end (a "coupon collector" effect, not a bug).

`.github/workflows/refresh-catalog.yml` runs this automatically and for free: on a daily schedule (and on demand via the Actions tab's "Run workflow" button), a GitHub-hosted runner does 20 passes and commits the refreshed `catalog.json` straight back to the repo if anything changed. Nothing runs on your PC or phone for this.

The app itself (`_loadCatalog()` in `lib/main.dart`) fetches that file live from `raw.githubusercontent.com` every time it opens — a single small JSON GET, not a scrape — so new vspodex.app songs show up automatically after the next scheduled refresh, no app rebuild needed. If that fetch fails (offline, first launch before any network, GitHub hiccup), it falls back to the copy bundled into the APK at build time (`app/assets/catalog.json`), and falls back to placeholder mock data if even that's missing.

To manually force a scrape locally instead of waiting on the schedule:

```
cd catalog-scraper
npm install
npx playwright install chromium   # first time only
npm run scrape                    # or: PASS_COUNT=20 npm run scrape
```

## App behavior (v1 scope)

- Single screen: cover header, "Shuffle Play All" button, scrollable track list (thumbnail, title, artist) — deliberately no Add/Edit/Sort management row or bottom nav, since the catalog is auto-curated, not manually managed in-app.
- Shuffle-plays the whole catalog; when the shuffled queue finishes, it reshuffles and keeps looping forever.
- Mini-player bar: previous / play-pause toggle / next, plus a draggable progress bar.
- Background playback survives Home, screen off, and switching apps (see "How playback actually works" above).
- A Stop action on the persistent notification fully kills playback and the overlay — the in-app mini-player intentionally only has pause/resume, not a hard stop.
- No accounts, no manual curation, no server — the two permission grants (overlay + notifications) are the only setup.

## Building

```
cd app
flutter pub get
flutter run                    # test on a connected/emulated device
flutter build apk --release    # produces the APK to sideload
```
