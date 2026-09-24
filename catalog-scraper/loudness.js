// Reads YouTube's own loudness measurement for a video.
//
// YouTube measures every upload's integrated loudness at ingest and ships the
// result in the watch page's initial player data, so getting it is a single
// plain HTML GET — no audio download, no ffmpeg, no headless browser. The
// value is dB relative to YouTube's -14 LUFS reference (positive = louder
// than reference), which is exactly what the app's playback gain wants.
//
// Kept in its own module, separate from scrape.js, so loudness.test.js can
// check the real implementation without dragging in Playwright.
//
// Also holds the readers for the player's own loudness constants, so the
// scraper's sanity check and the test both work from the values that actually
// ship in OverlayService.kt rather than from copies that can drift.

import { readFileSync, existsSync } from 'node:fs';

// Relative to catalog-scraper/, which is where both scrape.js and the test
// run. The nested path is where these files belong once they're moved back
// into their real package directory (see claude/next-features-plan.md).
const PLAYER_PATHS = [
  '../app/android/app/src/main/kotlin/OverlayService.kt',
  '../app/android/app/src/main/kotlin/com/soozyyy/vspomusic/vspo_music/OverlayService.kt',
];

/** Locates and reads the shipping player source. Throws if it has moved. */
export function readPlayerSource() {
  const path = PLAYER_PATHS.find((p) => existsSync(p));
  if (!path) {
    throw new Error(
      `OverlayService.kt not found. Looked in:\n  ${PLAYER_PATHS.join('\n  ')}\n` +
        'If the file moved, add its path to PLAYER_PATHS in loudness.js.',
    );
  }
  return { path, src: readFileSync(path, 'utf-8') };
}

/**
 * Pulls the loudness constants out of the injected script. One source of
 * truth: change TARGET_OFFSET_DB in the Kotlin file and both the scraper's
 * warnings and the test follow automatically.
 */
export function playerConstants(src) {
  const num = (name) => {
    const m = src.match(new RegExp(`var ${name} = (-?[\\d.]+);`));
    if (!m) throw new Error(`could not find "var ${name} = ...;" in the player source`);
    return Number(m[1]);
  };
  return {
    TARGET_OFFSET_DB: num('TARGET_OFFSET_DB'),
    MIN_GAIN: num('MIN_GAIN'),
    MAX_GAIN: num('MAX_GAIN'),
  };
}

/**
 * Emits a warning that stands out: a GitHub Actions annotation (shown on the
 * run's summary page) when running in CI, a plain console warning otherwise.
 */
export function warn(msg) {
  if (process.env.GITHUB_ACTIONS === 'true') {
    console.log(`::warning::${msg.replace(/\n/g, '%0A')}`);
  } else {
    console.warn(`WARNING: ${msg}`);
  }
}

/**
 * Pulls loudnessDb out of watch-page HTML. Returns null if the field isn't
 * there, rather than throwing — a page that fails to parse should cost one
 * song's value, not the whole run.
 */
export function extractLoudnessDb(html) {
  // Prefer playerConfig.audioConfig — the per-video value YouTube's player
  // normalizes with. The page also carries per-format copies (one per audio
  // stream in streamingData.adaptiveFormats) which have matched it to within
  // 0.01 dB in every live check so far, so they're only the fallback.
  const m =
    html.match(/"audioConfig"\s*:\s*\{[^}]*?"loudnessDb"\s*:\s*(-?[\d.]+)/) ||
    html.match(/"loudnessDb"\s*:\s*(-?[\d.]+)/);
  if (!m) return null;
  const value = Number(m[1]);
  return Number.isFinite(value) ? Number(value.toFixed(2)) : null;
}

/**
 * Fetches one video's watch page and extracts its loudness.
 * Returns null on any failure (network, non-200, field missing) so one bad
 * video can't abort a run; the caller keeps whatever is already in
 * catalog.json in that case.
 */
export async function fetchLoudnessDb(videoId) {
  try {
    const res = await fetch(`https://www.youtube.com/watch?v=${videoId}`, {
      headers: { 'accept-language': 'en-US,en;q=0.9' },
    });
    if (!res.ok) return null;
    return extractLoudnessDb(await res.text());
  } catch {
    return null;
  }
}
