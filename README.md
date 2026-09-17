# VspoM

A personal, single-user Android app for listening to VSpo! member music (sourced from YouTube, catalog curated by [vspodex.app](https://www.vspodex.app)'s `/music` page) in the background — screen off, other apps open, one screen, shuffle-play-all with continuous looping. Think "a tiny personal Spotify for VSpo songs."

No server, no backend, no ongoing cost, and nothing needs to run on a home PC. The catalog refreshes itself via a free GitHub Actions schedule; the app itself just plays music.

This is a **personal-use sideload**, not a Play Store app — no app store listing, no plan to publish it there. It's built for one person's own phone (and anyone else who wants to sideload it the same way).

## Installing it on your phone (no PC, no Flutter needed)

Every push to `main` automatically builds a signed APK on GitHub's own servers and publishes it to this repo's **[Releases page](https://github.com/soozyyy/VspoM/releases/latest)** — that's the easiest way to get the app, and the only thing you need is the phone itself.

1. On your phone, open the **[latest release](https://github.com/soozyyy/VspoM/releases/latest)** and download `app-release.apk`.
2. Open the downloaded file. Android will ask you to allow installs from that source (your browser or Files app) the first time — approve it, then tap Install. This is the normal "sideloading" flow for any app that isn't from the Play Store.
3. **First launch — grant two permissions when prompted** (both are one-time, and both matter — the app won't work correctly without them):
   - **"Draw over other apps"** — lets the app keep playing audio when your screen is off or you switch to another app. Without it, the app only "kind of" works while it's the one on screen.
   - **Notifications** — without this, the persistent playback notification (with its Stop button) never appears, and there's no way to fully stop playback.
4. Tap **Shuffle Play All** and it starts playing. Turn the screen off, switch apps, whatever — it keeps going.

To update later, just download the newer `app-release.apk` from the same Releases page and install it over the old one — every build is signed with the same key, so it installs as a normal update rather than needing an uninstall first.

### Building it yourself instead

If you'd rather build from source (e.g. to test a change before it's pushed), see Requirements below, then:

```
git clone https://github.com/soozyyy/VspoM.git
cd VspoM/app
flutter pub get
flutter build apk --release
```

The APK lands at `app/build/app/outputs/flutter-apk/app-release.apk` — copy it to your phone the same way (USB transfer, Google Drive, etc.) and install it as in step 2 above. Without a local `android/key.properties` set up (see "Releasing new builds" below), this builds signed with the debug key instead of the release one, which still installs fine on its own but won't match the signature of Releases-page builds — so pick one signing source and stick with it if you plan to keep updating over the same install.

## Requirements

**To just install and use the app:** an Android phone. That's it — see "Installing it on your phone" above.

**To build the APK yourself instead (your computer, one-time setup):**
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (this project targets Dart `^3.10.1`, whatever ships with a reasonably current Flutter stable release)
- Android SDK + platform tools (comes bundled if you install Android Studio; `flutter doctor` will point out anything missing)
- Windows, macOS, or Linux — Flutter's Android build tooling works the same on all three

**To run the app (your phone):**
- Android 8.0 (API 26) or newer
- Android 13+ phones additionally need the runtime notification permission (the app asks for this automatically)
- An internet connection at launch, to fetch the current song catalog (falls back to a bundled offline copy if there's no connection yet)
- "Install unknown apps" allowed for whichever app you use to open the APK file (Android prompts for this automatically the first time)

There is nothing to sign up for, no account, and no ongoing cost — the whole thing runs off GitHub's free tiers (Actions minutes, raw file hosting) plus whatever's already on your phone.

## What the app actually does

- One screen: a search box, a header showing either the VSpo logo (nothing playing yet) or the current song's thumbnail, a "Shuffle Play All" button, and a scrollable list of every song in the catalog (thumbnail, title, artist).
- **Search** matches song titles and artist names — including matching a romanized query against a kanji/kana artist name (e.g. typing "yaku" finds 八雲べに), the same way vspodex.app's own search behaves. It works off vspodex.app's own artist-slug romanization, scraped alongside each song.
- **Shuffle Play All** shuffles and loops the whole catalog forever. Search first, then hit Shuffle Play All while the list is filtered, and it shuffles and loops just the filtered songs instead (the button relabels itself to say how many songs it'll play).
- Tapping any individual song plays it immediately and continues shuffling from the full catalog afterward, regardless of any active search filter.
- A mini-player at the bottom shows previous / play-pause / next controls and a draggable progress bar for whatever's currently playing.
- Background playback survives turning the screen off, opening other apps, and switching away entirely — see "How playback actually works" below for why that's normally hard to pull off.
- The persistent playback notification shows the current song's title and artist (not a generic "VSpo Music" label), and its **Stop** button is the one true "fully stop everything" control; the in-app mini-player intentionally only has pause/resume, matching how most background-audio apps separate "pause for a second" from "I'm done."
- Deliberately excluded: no accounts, no manual song curation, no Add/Edit/Sort UI, no bottom navigation — the catalog is entirely auto-fetched from vspodex.app, so there's nothing to manage by hand.

## How playback actually works

YouTube's web player renders video into an Android `SurfaceView`, and Android tears that Surface down (killing the video decoder, and the audio riding the same codec pipeline) the instant the hosting Activity's window stops being visible. That means a normal in-app WebView player dies the moment you background the app or turn the screen off — which ruled out every "just embed a WebView in the screen" approach.

The fix: `OverlayService` (`app/android/.../OverlayService.kt`) runs as a foreground `Service` and adds a plain `android.webkit.WebView` directly to the `WindowManager` as an invisible 1×1 `TYPE_APPLICATION_OVERLAY` window — a system-level window with no relationship to the app's own Activity window. Backgrounding, closing, or switching away from the app has zero effect on it, so its video Surface (and the audio track riding it) never gets torn down. This is the same mechanism real background-audio apps rely on.

Flutter talks to this native layer through a single `MethodChannel` (`vspo_music/overlay`): `playVideo`, `pause`, `resume`, `seek`, `getPosition`, `stop`, plus permission checks for the overlay and notifications. No `just_audio`, `audio_service`, or `youtube_explode_dart` — playback is 100% native Android, driven from Dart.

### Volume normalization

Different YouTube uploads are mastered at very different loudness, and YouTube's own per-account "Stable volume" normalization isn't usable from a plain embedded WebView (it requires being signed in). Instead, the JS injected into the overlay's WebView builds a small Web Audio pipeline on every video: a compressor to even out a song's own internal dynamics, a boost-only leveler that raises quiet uploads toward a target level (never lowers an already-loud one), and a limiter to keep the result from ever clipping. It's an approximation, not true LUFS-matched normalization like Spotify's precomputed loudness data, but it noticeably closes the gap between quiet and loud uploads.

## Keeping the catalog in sync with vspodex.app

vspodex.app has no public JSON API (it's a Next.js Server Actions app, and `/api` is explicitly disallowed by its `robots.txt` anyway) — `/music` itself is allowed, so `catalog-scraper/scrape.js` reads that rendered page with a headless browser (Playwright) instead.

One quirk that shaped the whole design: `/music` doesn't serve a stable, complete list — every page load (and every refresh) returns a random ~60-80 track sample of the full catalog. So the scraper does several fresh-page-load passes in one run and merges everything it finds — deduped by YouTube video ID — into whatever `catalog.json` already exists, rather than overwriting it. Coverage climbs toward the full catalog with more passes and more runs over time (a "coupon collector" effect, not a bug).

`.github/workflows/refresh-catalog.yml` runs this automatically and for free: on a daily schedule (and on demand via the repo's Actions tab → "Run workflow"), a GitHub-hosted runner does 20 passes and commits the refreshed `catalog.json` straight back to the repo if anything changed. Nothing runs on your PC or phone for this.

The app itself (`_loadCatalog()` in `lib/main.dart`) fetches that file live from `raw.githubusercontent.com` every time it opens — a single small JSON GET, not a scrape — so new vspodex.app songs show up automatically after the next scheduled refresh, no app rebuild needed. If that fetch fails (offline, first launch before any network, GitHub hiccup), it falls back to the copy bundled into the APK at build time (`app/assets/catalog.json`), and falls back to placeholder mock data if even that's missing.

To manually force a scrape locally instead of waiting on the schedule:

```
cd catalog-scraper
npm install
npx playwright install chromium   # first time only
npm run scrape                    # or: PASS_COUNT=20 npm run scrape
```

## Project layout

```
VspoM/
  README.md
  .github/workflows/
    refresh-catalog.yml   # scheduled + manual catalog refresh
    build-apk.yml          # builds a signed APK and publishes it to Releases
  catalog-scraper/
    package.json
    scrape.js         # Playwright scraper against vspodex.app's public /music page
    catalog.json       # generated output, kept in sync by the workflow above
  app/                 # Flutter project (created via `flutter create app`)
    lib/main.dart       # the whole UI + playback control logic
    android/
      key.properties.example  # template for the (git-ignored) release signing config
      app/src/main/kotlin/.../
        MainActivity.kt    # MethodChannel handler
        OverlayService.kt  # the background-playback engine (see above)
    assets/
      catalog.json            # bundled fallback copy, used offline / before first successful fetch
      branding/vspo_logo.png  # shown as the header image before anything is playing
      icon/vspo_icon.png      # source image for the app's launcher icon
```

## Performance notes

The song list renders roughly 340 thumbnails as you scroll. Thumbnails load through `cached_network_image` rather than a plain network image widget, decoded straight down to their small on-screen size (instead of decoding vspodex.app's full-resolution source image just to shrink it visually) and cached to disk — this is what keeps scrolling smooth and avoids re-downloading every thumbnail each time the app is reopened.

## Releasing new builds (maintainer notes)

`.github/workflows/build-apk.yml` builds a release APK on every push to `main` and publishes it to a rolling `latest` GitHub Release — this is what powers the "Installing it on your phone" section above. It needs two repo secrets (**Settings → Secrets and variables → Actions**) so CI can sign the APK with the project's dedicated `vspo-release` keystore instead of a throwaway debug key:

- `VSPO_KEYSTORE_BASE64` — the keystore file, base64-encoded
- `VSPO_KEYSTORE_PASSWORD` — its store/key password

Both were generated once and are **not** committed to the repo (see `android/key.properties.example` for the format, and `.gitignore` for what's excluded — `android/key.properties` and `android/app/keystore/`). To build locally with the same signing key GitHub Actions uses (so your local builds and Releases-page builds are interchangeable installs), copy `android/key.properties.example` to `android/key.properties`, fill in the real values, and place the matching `vspo-release.keystore` file at `android/app/keystore/vspo-release.keystore`. Without that local setup, `flutter build apk --release` still works — it just falls back to the debug key, which won't match Releases-page builds signature-wise (fine for a one-off test build, not for installing over an existing sideload).

If the keystore is ever lost, a new one can be generated (`keytool -genkeypair ...`) and the secrets updated — but every phone that has an existing install would then need to uninstall it once before the new signature can be installed, since Android treats a change of signing key as an entirely different app for update purposes.

## Building from source

```
cd app
flutter pub get
flutter run                    # test on a connected/emulated device
flutter build apk --release    # produces the APK to sideload — see "Installing it on your phone" above
```
