// One-time / occasional scraper for vspodex.app's /music page.
//
// vspodex.app has no public JSON API (confirmed: it's a Next.js Server Actions
// app, not a REST endpoint), so this reads the rendered page directly with a
// headless browser instead.
//
// The page lazy-mounts artist sections as you scroll (only ~60 of the 343
// tracks are in the DOM on initial load), so this script scrolls repeatedly,
// collecting newly-rendered <article> track cards each time, deduped by
// YouTube video ID (extracted from the thumbnail URL, e.g.
// https://i.ytimg.com/vi/<videoId>/maxresdefault.jpg), until no new tracks
// appear for several scrolls in a row.
//
// Usage:
//   npm install
//   npx playwright install chromium   # first time only
//   npm run scrape
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
import { writeFileSync } from 'node:fs';

const MUSIC_URL = 'https://www.vspodex.app/zh-Hant/music';
const EXPECTED_TOTAL = 343; // shown on the page as "343 首" at time of writing; just a hint, not enforced
const MAX_SCROLLS = 400;
const STALL_LIMIT = 8; // stop after this many consecutive scrolls with no new tracks
const SCROLL_WAIT_MS = 350;

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

async function main() {
  console.log(`Launching headless browser -> ${MUSIC_URL}`);
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.goto(MUSIC_URL, { waitUntil: 'networkidle' });
  await page.waitForSelector('article', { timeout: 15000 });

  const tracks = new Map(); // videoId -> track
  let stall = 0;

  for (let i = 0; i < MAX_SCROLLS; i++) {
    const visible = await extractVisibleTracks(page);
    let added = 0;
    for (const t of visible) {
      if (!tracks.has(t.videoId)) {
        tracks.set(t.videoId, t);
        added++;
      }
    }

    if (added === 0) {
      stall++;
    } else {
      stall = 0;
    }

    console.log(
      `scroll ${i + 1}: +${added} new, ${tracks.size} unique so far` +
        (stall > 0 ? ` (stall ${stall}/${STALL_LIMIT})` : '')
    );

    if (stall >= STALL_LIMIT) {
      console.log('No new tracks after several scrolls — assuming end of list.');
      break;
    }

    await page.evaluate(() => window.scrollBy(0, window.innerHeight * 2));
    await page.waitForTimeout(SCROLL_WAIT_MS);
  }

  await browser.close();

  const result = Array.from(tracks.values()).sort((a, b) => {
    if (a.artistName === b.artistName) return a.title.localeCompare(b.title);
    return (a.artistName || '').localeCompare(b.artistName || '');
  });

  writeFileSync('catalog.json', JSON.stringify(result, null, 2), 'utf-8');
  console.log(`\nWrote catalog.json with ${result.length} tracks.`);
  if (result.length !== EXPECTED_TOTAL) {
    console.log(
      `Note: expected around ${EXPECTED_TOTAL} tracks (site's displayed count at the time this ` +
        `script was written) but got ${result.length}. The site's count may have changed since, ` +
        `or the scroll-stall settings may need tuning (try raising STALL_LIMIT/MAX_SCROLLS).`
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
