// Scraper for vspodex.app's /music page — designed to run both by hand and
// on a schedule via GitHub Actions (see .github/workflows/refresh-catalog.yml).
//
// vspodex.app has no public JSON API (confirmed: it's a Next.js Server Actions
// app, not a REST endpoint — and robots.txt explicitly disallows /api anyway),
// so this reads the rendered /music page directly with a headless browser
// instead, which robots.txt explicitly allows.
//
// IMPORTANT: the /music page does not show a stable, complete list — each
// load (and each refresh) serves a random SAMPLE of the catalog, roughly
// 60-80 tracks, and scrolling within one load only reveals what's in that
// particular sample (confirmed by testing: repeated loads plateaued at
// different counts each time, with scrolling working correctly). So one
// page load can never reach the full ~343 on its own.
//
// To get there anyway, this script does multiple PASSES automatically in one
// run — reloading the page fresh each time (a fresh load = a fresh random
// sample) — and accumulates everything into one deduped map (by YouTube
// video ID), merged with whatever catalog.json already exists on disk.
// Coverage climbs with more passes but with diminishing returns near the end
// (a "coupon collector" effect — normal for random sampling, not a bug).
//
// Usage:
//   npm install
//   npx playwright install chromium   # first time only
//   npm run scrape                    # runs PASS_COUNT passes, writes catalog.json
//
// Output: catalog.json in this folder, e.g.:
// [
//   {
//     "videoId": "I84zUHUvHWE",
//     "title": "星座になれたら",
//     "artistName": "藍沢エマ / Aizawa Ema",
//     "artistSlug": "aizawa-ema",
//     "thumbnail": "https://i.ytimg.com/vi/I84zUHUvHWE/maxresdefault.jpg"
//   },
//   ...
// ]

import { chromium } from 'playwright';
import { writeFileSync, readFileSync, existsSync } from 'node:fs';

const MUSIC_URL = 'https://www.vspodex.app/zh-Hant/music';
const EXPECTED_TOTAL = 343; // shown on the page as "343 首" at time of writing; just a hint, not enforced
const MAX_SCROLLS = 400;
const STALL_LIMIT = 12; // stop a pass after this many consecutive scrolls with no new tracks
const SCROLL_WAIT_MS = 600;
// How many fresh-page-load passes to do in one invocation. Each pass gets
// its own random sample; more passes = better coverage but more runtime.
// Override with PASS_COUNT=N in the environment (used by the scheduled
// GitHub Actions run to do a thorough sweep unattended).
const PASS_COUNT = Number(process.env.PASS_COUNT) || 10;

async function extractVisibleTracks(page) {
  return page.evaluate(() => {
    return Array.from(document.querySelectorAll('article'))
      .map((a) => {
        const img = a.querySelector('img');
        const heading = a.querySelector('h1,h2,h3,h4,h5,h6');
        const artistLink = a.querySelector('a[href^="/music/artist/"]');
        const src = img ? img.getAttribute('src') || '' : '';
        const match = src.match(/\/vi(?:_webp)?\/([a-zA-Z0-9_-]{11})\//);
        return {
          videoId: match ? match[1] : null,
          title: heading ? heading.textContent.trim() : null,
          artistName: artistLink ? artistLink.textContent.trim() : null,
          artistSlug: artistLink
            ? artistLink.getAttribute('href').split('/').filter(Boolean).pop()
            : null,
          thumbnail: src || null,
        };
      })
      .filter((t) => t.videoId && t.title);
  });
}

async function runOnePass(browser, tracks) {
  const page = await browser.newPage();
  try {
    // 'networkidle' never fires on this site within a reasonable timeout —
    // it's a heavy SPA that keeps some connection open in the background
    // (analytics/live-stream polling, etc.). Waiting for the DOM plus the
    // first track card to appear is a more reliable signal here.
    await page.goto(MUSIC_URL, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForSelector('article', { timeout: 30000 });

    let stall = 0;
    let passAdded = 0;

    for (let i = 0; i < MAX_SCROLLS; i++) {
      const visible = await extractVisibleTracks(page);
      let added = 0;
      for (const t of visible) {
        if (!tracks.has(t.videoId)) {
          tracks.set(t.videoId, t);
          added++;
        }
      }
      passAdded += added;
      stall = added === 0 ? stall + 1 : 0;

      if (stall >= STALL_LIMIT) break;

      // Plain window.scrollBy() only moves the outer page — on this site
      // the track list lives inside its own internally-scrolling container,
      // so that was a no-op. Scrolling the last known card into view moves
      // whichever ancestor is actually scrollable, regardless of layout.
      await page.evaluate(() => {
        const articles = document.querySelectorAll('article');
        const last = articles[articles.length - 1];
        if (last) {
          last.scrollIntoView({ block: 'end' });
        } else {
          window.scrollBy(0, window.innerHeight * 2);
        }
      });
      await page.waitForTimeout(SCROLL_WAIT_MS);
    }

    return passAdded;
  } finally {
    await page.close();
  }
}

async function main() {
  const tracks = new Map(); // videoId -> track
  let previousCount = 0;
  if (existsSync('catalog.json')) {
    try {
      const existing = JSON.parse(readFileSync('catalog.json', 'utf-8'));
      for (const t of existing) {
        if (t && t.videoId) tracks.set(t.videoId, t);
      }
      previousCount = tracks.size;
      console.log(`Loaded ${previousCount} existing tracks from catalog.json — accumulating.`);
    } catch (e) {
      console.log('Could not read existing catalog.json, starting fresh:', e.message);
    }
  }

  console.log(`Launching headless browser -> ${MUSIC_URL} (${PASS_COUNT} passes)`);
  const browser = await chromium.launch();

  try {
    for (let pass = 1; pass <= PASS_COUNT; pass++) {
      const added = await runOnePass(browser, tracks);
      console.log(`pass ${pass}/${PASS_COUNT}: +${added} new, ${tracks.size} unique so far`);
    }
  } finally {
    await browser.close();
  }

  const result = Array.from(tracks.values()).sort((a, b) => {
    if (a.artistName === b.artistName) return a.title.localeCompare(b.title);
    return (a.artistName || '').localeCompare(b.artistName || '');
  });

  writeFileSync('catalog.json', JSON.stringify(result, null, 2), 'utf-8');
  const newThisRun = result.length - previousCount;
  console.log(
    `\nWrote catalog.json with ${result.length} tracks total ` +
      `(+${newThisRun} new this run, had ${previousCount} before).`
  );
  if (result.length < EXPECTED_TOTAL) {
    console.log(
      `Still short of the expected ~${EXPECTED_TOTAL}. Run "npm run scrape" again, or raise ` +
        `PASS_COUNT (e.g. "PASS_COUNT=20 npm run scrape") for a more thorough sweep — each run ` +
        `merges its findings into catalog.json rather than replacing it.`
    );
  } else {
    console.log('Reached (or passed) the expected total — looking good!');
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
