<div align="center">

<img src="app/assets/icon/vspo_icon.png" width="120" alt="VspoM icon">

# VspoM

**A background music player for VSPO! and HIMEHINA songs on Android.**<br>
Every VSPO! member song and every HIMEHINA song, shuffled and looping, even with the screen off.

[![Version](https://img.shields.io/badge/version-v1.0.22-blue)](https://github.com/soozyyy/VspoM/releases/latest)
[![APK size](https://img.shields.io/badge/APK-52%20MB-green)](https://github.com/soozyyy/VspoM/releases/latest)
[![Android](https://img.shields.io/badge/Android-8.0%2B-brightgreen?logo=android&logoColor=white)](#install)

[**⬇ Download APK**](https://github.com/soozyyy/VspoM/releases/download/latest/app-release.apk) · [**🌐 Open the website**](https://soozyyy.github.io/VspoM/)

</div>

## Features

- **Two pages, VSPO! and HIMEHINA**: switch in the ☰ menu. Each has its own songs, artists, playlists and colours (VSPO! purple, HIMEHINA pink and blue), and the music keeps playing when you switch.
- **Background playback.** Keeps playing with the screen off or while you use other apps.
- **Shuffle everything**, or just one artist, or just your search results. It loops forever.
- **Search** by song or artist, including romanized names (typing "yaku" finds 八雲べに).
- **Now Playing screen** with a big seek bar and an **Up Next** queue, in the **Queue** tab at the bottom. It also shows what plays when the queue loops. Tap any upcoming song to jump to it, or ✕ to take it out of the queue.
- **Browse by Artist**, ordered from senpai to kohai (JP by debut, then EN).
- **Playlists**: make as many as you like from the **Playlists** tab. Add songs one at a time, or a whole channel at once, drag to reorder, search inside a playlist, then shuffle or play in order.
- **Lock-screen and notification controls**: Previous, Play/Pause, Next, plus song artwork and a draggable progress bar. Bluetooth, wired headphone and car buttons work too.
- **Even volume**: quiet and loud uploads play at about the same level, even if you open the app with no signal.
- **Always-fresh song list**: new songs appear as soon as the song list is refreshed, no app update needed. The next time you open the app, it shows you what's new.
- **News**: open the ☰ menu next to the search bar for a News page with every update and every new song, with dates. Tap a card for the full list of changes.
- **Updates inside the app**: when a new version is out, the app shows what's new and installs it for you.
- No account, no ads, no server. It's free to run.

## Install

1. On your phone, download **[app-release.apk](https://github.com/soozyyy/VspoM/releases/download/latest/app-release.apk)** (about 52 MB).
2. Open it and tap **Install**. The first time, Android will ask you to allow installs from your browser or Files app. That's normal for any app from outside the Play Store.
3. Open VspoM and allow **Display over other apps** when it asks. This is what keeps music playing in the background. (No notification permission is needed: the playback controls show up anyway.)
4. Tap **Shuffle Play All**.

**Updating:** you don't need to come back here. When a new version is released, the app asks you on launch. Tap **Update**, then **Install**. The permissions you already granted are kept.

## Website (PC)

On a computer, open **[soozyyy.github.io/VspoM](https://soozyyy.github.io/VspoM/)** in your browser. Nothing to install. It has the same two pages as the app, VSPO! and HIMEHINA, with the same songs, shuffle, search, artists, queue and playlists, laid out for a big screen, and music keeps playing in a background tab. Press **Space** to play or pause.

A few differences from the app:

- **Playlists are saved in that browser only.** They don't sync with the app or with other browsers.
- **No News page or update popups.** The website is always the latest version.
- **Some songs may be skipped.** A few uploaders don't allow their videos to play on other sites. The website skips those and tells you.
- Made for computers. On a phone, use the app: phone browsers stop the music when you lock the screen.

## FAQ

**Why does it need "Display over other apps"?**
The music plays through YouTube in a tiny invisible window. Android shuts down video playback in normal app screens when you leave them, but not in an overlay window. Nothing is ever drawn on your screen.

**How do I stop playback completely?**
Swipe VspoM away from your recent apps, or pause and swipe the notification away.

**Why isn't it on the Play Store?**
It's a personal project, shared as-is for anyone who wants to sideload it.

**Where do the songs come from?**
The VSPO! song list comes from [vspodex.app](https://www.vspodex.app)'s music page. The HIMEHINA song list comes straight from their YouTube channel: their own song playlists, plus YouTube's official album uploads for songs that have no video. Both are refreshed whenever the maintainer runs the scrapers, and the audio streams from the original YouTube uploads.

---

## For developers

### How background playback works

`OverlayService.kt` is a foreground service that attaches a plain `WebView` straight to the `WindowManager` as an invisible 1×1 `TYPE_APPLICATION_OVERLAY` window. That window isn't tied to the app's Activity, so backgrounding the app or turning off the screen never tears down its video surface, and the audio keeps going. Flutter drives it over one `MethodChannel` (`vspo_music/overlay`: `playVideo`, `pause`, `resume`, `seek`, `getPosition`, `stop`, and more). One `EventChannel` (`vspo_music/overlay_events`) carries lock-screen and hardware skip presses back up to Dart, which owns the shuffle order. A `MediaSessionCompat` powers the lock-screen and notification controls. There's no `just_audio`, `audio_service` or `youtube_explode_dart`.

**Volume leveling:** each song's `loudnessDb` (read from YouTube's own watch page by the scraper) is stored in the catalog. The injected script turns loud songs down with `video.volume`, and only boosts the rare quiet song through Web Audio. The level is decided once when a song starts and held there: a `volumechange` listener puts it straight back if YouTube moves it. If the catalog has no value for a song, the script reads the same `loudnessDb` from the YouTube page itself. `catalog-scraper/loudness.test.js` guards all of this; the APK build runs it strictly, the scraper only as warnings, so it can never stop new songs from arriving.

### How the song list stays current

vspodex.app has no public API, and `/music` returns a random ~60–80 song sample per page load. So `catalog-scraper/scrape.js` (Playwright) loads it many times and merges the results by video ID into `catalog.json`. It runs by hand on a home PC and the result is committed: since September 2026 vspodex.app's Cloudflare check blocks cloud servers, so it can't run on GitHub Actions. The app fetches `catalog.json` from `raw.githubusercontent.com` on every launch, so a new song needs no rebuild. If that fetch fails, it uses the last list it downloaded, then the copy bundled in the APK (refreshed from `catalog.json` on every build).

Refresh the catalog (PowerShell):

```
cd catalog-scraper
npm install
npx playwright install chromium   # first time only
$env:PASS_COUNT=20; npm run scrape
git add catalog.json
git commit -m "Refresh catalog"
git push
```

The app picks up the pushed `catalog.json` on its next launch, no rebuild needed. If a scrape prints "No track cards", it saves `debug-screenshot.png` showing what the page served instead.

The HIMEHINA page's list is `himehina.json`, built by `catalog-scraper/himehina.js` with no browser or API key. It reads the channel's ORIGINAL MUSIC and COVER MUSIC playlists and the three "- Topic" channels (YouTube's album uploads), keeps one upload per song (the channel's full video first, else the Topic audio; never Dance Videos, ShortMVs, live tracks or interludes), and merges into the existing file. One-off fixes go in `himehina-sources.json`. Run `npm run himehina`, then commit `himehina.json`. `npm run test:himehina` checks the song rules.

### Build from source

```
cd app
flutter pub get
flutter run                    # on a connected device
flutter build apk --release    # APK at app/build/app/outputs/flutter-apk/app-release.apk
```

Without `android/key.properties`, release builds are signed with the debug key. They won't install over a Releases-page build, and a local build always reports version 1, so the app will always offer the update.

### Releases

Every push to `main` that touches `app/` runs `.github/workflows/build-apk.yml`. It builds a signed APK as version `1.0.<run number>` and publishes it to the rolling [`latest`](https://github.com/soozyyy/VspoM/releases/latest) release along with a `version.json`. The app reads that file to decide whether to offer an update.

- **Update notes** come from `app/whats-new.txt` if the push changed it. Otherwise they come from the latest commit's title.
- **News page history** is `app/assets/changelog.json` (the app reads it live from GitHub, with the bundled copy as fallback). Add an entry to it with every release: `notes` is the short summary (same text as `whats-new.txt`), `details` lists every change, one line each, and shows when you tap the card. New songs come from each song's `addedAt` date, which `scrape.js` stamps the first time it finds a song.
- **Signing** needs two repo secrets: `VSPO_KEYSTORE_BASE64` and `VSPO_KEYSTORE_PASSWORD`. The keystore and `key.properties` are git-ignored; `android/key.properties.example` shows the format. If the keystore is ever lost, existing installs have to uninstall once, because Android treats a new signing key as a different app.

### Website

`website/` is a separate Flutter web project: its own copy of the app's code, changed freely without ever touching `app/`. App features are copied over by hand when they fit the website. Instead of `OverlayService.kt`, it plays songs with YouTube's IFrame Player API in an invisible player (`web/player.js`), and it keeps playlists in the browser's `localStorage`. Volume leveling uses the same catalog `loudnessDb` and the same -6 dB target, applied through the player's volume (`lib/level.dart`); songs quieter than the target can't be boosted there.

Every push to `main` that touches `website/` runs `.github/workflows/deploy-website.yml`, which builds the site and publishes it to GitHub Pages. It never triggers an APK build, and app pushes never redeploy the website. The website has no version number. (One-time setup: Settings → Pages → Source: GitHub Actions.)

```
cd website
flutter pub get
flutter run -d chrome          # local preview
```

### Project layout

```
VspoM/
  .github/workflows/
    build-apk.yml          # build, sign, release, version.json
    deploy-website.yml     # build the website, publish to GitHub Pages
  catalog-scraper/
    scrape.js              # vspodex.app scraper (Playwright)
    himehina.js            # HIMEHINA scraper (plain YouTube pages)
    himehina-core.js       # what counts as a song, merging (tested by himehina.test.js)
    himehina-sources.json  # HIMEHINA playlists, Topic channels, manual fixes
    loudness.js            # loudness extraction + shared player constants
    loudness.test.js       # volume-leveling checks (npm test = scraper checks, npm run test:app = APK build)
    catalog.json           # the VSPO! song list the app fetches
    himehina.json          # the HIMEHINA song list the app fetches
  app/                     # Flutter project
    lib/main.dart          # main screen + playback sequencing
    lib/catalog.dart       # Song model + loading the song list
    lib/playlists.dart     # Playlists tab + playlist pages
    lib/widgets.dart       # thumbnails + Artists order
    lib/update_dialog.dart # in-app update check + dialog
    lib/news.dart          # side menu, News page, new-songs popup
    whats-new.txt          # notes shown in the in-app update popup
    android/app/src/main/kotlin/
      MainActivity.kt      # channel handlers, version check, APK install
      OverlayService.kt    # playback engine + MediaSession
    assets/                # bundled catalog fallback, changelog.json (News), logo, icon
  website/                 # Flutter web project (separate copy of the app's code)
    lib/                   # same layout as app/lib, minus updater and News
    lib/web_bridge.dart    # Dart side of web/player.js
    lib/level.dart         # volume leveling through the player's volume
    web/player.js          # YouTube IFrame player, localStorage, fetch
```

---

## Credits & disclaimer

The VSPO! song list comes from [vspodex.app](https://www.vspodex.app); the HIMEHINA list from their YouTube channel. All music belongs to its creators and is streamed from YouTube.

VspoM is an unofficial fan project. It is not affiliated with or endorsed by VSPO!, Brave group, YouTube or Google.
