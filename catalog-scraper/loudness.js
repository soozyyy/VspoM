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

/**
 * Pulls loudnessDb out of watch-page HTML. Returns null if the field isn't
 * there, rather than throwing — a page that fails to parse should cost one
 * song's value, not the whole run.
 */
export function extractLoudnessDb(html) {
  const m = html.match(/"loudnessDb"\s*:\s*(-?[\d.]+)/);
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
