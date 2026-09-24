<div align="center">

<img src="app/assets/icon/vspo_icon.png" width="120" alt="VspoM icon">

# VspoM

**A background music player for VSPO! songs on Android.**<br>
Every VSPO! member song, shuffled and looping, even with the screen off.

[![Version](https://img.shields.io/badge/version-v1.0.17-blue)](https://github.com/soozyyy/VspoM/releases/latest)
[![APK size](https://img.shields.io/badge/APK-52%20MB-green)](https://github.com/soozyyy/VspoM/releases/latest)
[![Android](https://img.shields.io/badge/Android-8.0%2B-brightgreen?logo=android&logoColor=white)](#install)

[**⬇ Download APK**](https://github.com/soozyyy/VspoM/releases/download/latest/app-release.apk)

</div>

## Features

- **Background playback.** Keeps playing with the screen off or while you use other apps.
- **Shuffle everything**, or just one artist, or just your search results. It loops forever.
- **Search** by song or artist, including romanized names (typing "yaku" finds 八雲べに).
- **Now Playing screen** with a big seek bar and an **Up Next** queue. Tap any upcoming song to jump to it.
- **Browse by Artist**, ordered from senpai to kohai (JP by debut, then EN).
- **Lock-screen and notification controls**: Previous, Play/Pause, Next, plus song artwork and a draggable progress bar. Bluetooth, wired headphone and car buttons work too.
- **Even volume**: quiet and loud uploads play at about the same level, even if you open the app with no signal.
- **Always-fresh song list**: new songs appear automatically every day, no app update needed.
- **Updates inside the app**: when a new version is out, the app shows what's new and installs it for you.
- No account, no ads, no server. It's free to run.

## Install

1. On your phone, download **[app-release.apk](https://github.com/soozyyy/VspoM/releases/download/latest/app-release.apk)** (about 52 MB).
2. Open it and tap **Install**. The first time, Android will ask you to allow installs from your browser or Files app. That's normal for any app from outside the Play Store.
3. Open VspoM and allow **Display over other apps** when it asks. This is what keeps music playing in the background. (No notification permission is needed: the playback controls show up anyway.)
4. Tap **Shuffle Play All**.

**Updating:** you don't need to come back here. When a new version is released, the app asks you on launch. Tap **Update**, then **Install**. The permissions you already granted are kept.

## FAQ

**Why does it need "Display over other apps"?**
The music plays through YouTube in a tiny invisible window. Android shuts down video playback in normal app screens when you leave them, but not in an overlay window. Nothing is ever drawn on your screen.

**How do I stop playback completely?**
Pause, then swipe the notification away.

**Why isn't it on the Play Store?**
It's a personal project, shared as-is for anyone who wants to sideload it.

**Where do the songs come from?**
The song list comes from [vspodex.app](https://www.vspodex.app)'s music page. It's refreshed daily, and the audio streams from the original YouTube uploads.

---

## For developers

### How background playback works

`OverlayService.kt` is a foreground service that attaches a plain `WebView` straight to the `WindowManager` as an invisible 1×1 `TYPE_APPLICATION_OVERLAY` window. That window isn't tied to the app's Activity, so backgrounding the app or turning off the screen never tears down its video surface, and the audio keeps going. Flutter drives it over one `MethodChannel` (`vspo_music/overlay`: `playVideo`, `pause`, `resume`, `seek`, `getPosition`, `stop`, and more). One `EventChannel` (`vspo_music/overlay_events`) carries lock-screen and hardware skip presses back up to Dart, which owns the shuffle order. A `MediaSessionCompat` powers the lock-screen and notification controls. There's no `just_audio`, `audio_service` or `youtube_explode_dart`.

**Volume leveling:** each song's `loudnessDb` (read from YouTube's own watch page by the scraper) is stored in the catalog. The injected script turns loud songs down with `video.volume`, and only boosts the rare quiet song through Web Audio. The level is decided once when a song starts and held there: a `volumechange` listener puts it straight back if YouTube moves it. If the catalog has no value for a song, the script reads the same `loudnessDb` from the YouTube page itself. `catalog-scraper/loudness.test.js` guards all of this; the APK build runs it strictly, the nightly scrape only as warnings, so it can never stop new songs from arriving.

### How the song list stays current

vspodex.app has no public API, and `/music` returns a random ~60–80 song sample per page load. So `catalog-scraper/scrape.js` (Playwright) loads it many times and merges the results by video ID into `catalog.json`. `.github/workflows/refresh-catalog.yml` runs this daily on GitHub's servers and commits the result. The app fetches `catalog.json` from `raw.githubusercontent.com` on every launch, so a new song needs no rebuild. If that fetch fails, it uses the last list it downloaded, then the copy bundled in the APK (refreshed from `catalog.json` on every build).

Run a scrape locally:

```
cd catalog-scraper
npm install
npx playwright install chromium   # first time only
npm run scrape                    # or: PASS_COUNT=20 npm run scrape
```

A local scrape only reaches the app once it's pushed.

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
- **Signing** needs two repo secrets: `VSPO_KEYSTORE_BASE64` and `VSPO_KEYSTORE_PASSWORD`. The keystore and `key.properties` are git-ignored; `android/key.properties.example` shows the format. If the keystore is ever lost, existing installs have to uninstall once, because Android treats a new signing key as a different app.

### Project layout

```
VspoM/
  .github/workflows/
    build-apk.yml          # build, sign, release, version.json
    refresh-catalog.yml    # daily catalog scrape
  catalog-scraper/
    scrape.js              # vspodex.app scraper (Playwright)
    loudness.js            # loudness extraction + shared player constants
    loudness.test.js       # volume-leveling checks (npm test = nightly, npm run test:app = APK build)
    catalog.json           # the song list the app fetches
  app/                     # Flutter project
    lib/main.dart          # all UI + playback sequencing
    whats-new.txt          # notes shown in the in-app update popup
    android/app/src/main/kotlin/
      MainActivity.kt      # channel handlers, version check, APK install
      OverlayService.kt    # playback engine + MediaSession
    assets/                # bundled catalog fallback, logo, icon
```

---

## Credits & disclaimer

The song list comes from [vspodex.app](https://www.vspodex.app). All music belongs to its creators and is streamed from YouTube.

VspoM is an unofficial fan project. It is not affiliated with or endorsed by VSPO!, Brave group, YouTube or Google.
