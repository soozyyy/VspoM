# VSpo Music App

Personal, single-user Android app for listening to VSpo! member music (sourced from
YouTube, catalog curated by vspodex.app's `/music` module) in the background, like Spotify.

No server, no backend, no ongoing cost. Everything runs on-device.

## Project layout

```
VspoM/
  README.md
  catalog-scraper/     # One-time/occasional Node+Playwright script -> catalog.json
    package.json
    scrape.js
    catalog.json        # generated output (343 tracks), also copied into app assets
  app/                  # Flutter project (created via `flutter create app`)
    lib/
      main.dart
      ...
```

## Workflow

1. **Catalog scraper** (`catalog-scraper/`): run manually whenever you want to refresh
   the song list. It scrapes vspodex.app's `/music` page(s) and writes `catalog.json`
   (title, artist, YouTube video ID, thumbnail, duration).
   ```
   cd catalog-scraper
   npm install
   npm run scrape
   ```
2. Copy/push the resulting `catalog.json` to the GitHub repo that hosts it (raw file
   URL), so the app can fetch the latest list on launch without needing a rebuild.
   The app also bundles a copy as a fallback for offline first-run.
3. **App** (`app/`): Flutter project. Build phases tracked in the project's `apk-plan.md`.
   ```
   cd app
   flutter pub get
   flutter run          # test on a connected/emulated device
   flutter build apk --release   # produces the APK to sideload
   ```

## App behavior (v1 scope)

- Single screen: list of all tracks (343 currently), grouped/shown with artist + thumbnail.
- "Shuffle Play" button: starts playing all tracks in random order.
- When the shuffled queue finishes, it reshuffles and keeps looping (continuous playback).
- Background playback: works with screen off / other apps open, with lock-screen and
  notification media controls.
- No accounts, no server. Local-only.

## Key libraries (Flutter)

- `just_audio` — audio playback engine
- `audio_service` — background service, lock-screen/notification controls, media session
- `youtube_explode_dart` — resolves a YouTube video ID to a direct playable audio stream,
  entirely on-device (no server needed)
- `http` — fetching the hosted `catalog.json` from GitHub on launch
