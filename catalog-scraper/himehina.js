// Builds himehina.json, the HIMEHINA page's song list, straight from YouTube.
// HimeHina are one channel, so there's no vspodex-style site to read: this
// takes their own song playlists plus the three "- Topic" channels (YouTube's
// auto-uploads of their albums, which have every released song, covers too).
// No browser, no API key, no npm packages: plain fetch of public pages.
//
// Usage (PowerShell):  cd catalog-scraper; npm run himehina
// Then commit + push himehina.json. The app reads it from GitHub on launch.
//
// What counts as a song, and which upload wins when a song exists twice,
// is in himehina-core.js. Fix one-off mistakes in himehina-sources.json:
//   exclude  {videoId: reason}  never list this upload
//   titles   {videoId: title}   use this title instead
//   include  [{videoId, title, singer: duo|hime|hina}]  add by hand
//
// Each song is also labelled "kind": "original" | "cover" from the channel
// playlist it's in and himehina.jp's discography tracklists, saved in
// himehina-site.json (see himehina-core.js and himehina-site-snippet.js). The
// app builds its Originals / Covers playlists from that.
//
// Every run merges into the existing himehina.json; songs are never removed
// because a run missed them. New songs get "addedAt" (today) so the app
// announces them, except on the very first run, which is the starting list.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import {
  parseChannelTitle,
  parseTopicTitle,
  mergeCatalog,
  addKinds,
} from './himehina-core.js';
import { fetchLoudnessDb } from './loudness.js';

const OUT = 'himehina.json';
const sources = JSON.parse(readFileSync('himehina-sources.json', 'utf-8'));
const TODAY = new Date().toLocaleDateString('sv'); // YYYY-MM-DD, local date
// hl=ja: YouTube translates titles to the viewer's language; we want the
// original Japanese ones.
const HEADERS = { 'accept-language': 'ja' };

async function getInitialData(url) {
  const res = await fetch(url, { headers: HEADERS });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  const html = await res.text();
  const m = html.match(/var ytInitialData = (\{.*?\});<\/script>/s);
  if (!m) throw new Error(`${url}: no ytInitialData (consent or bot page?)`);
  const clientVersion = html.match(/"INNERTUBE_CLIENT_VERSION":"([^"]+)"/)?.[1];
  return { data: JSON.parse(m[1]), clientVersion };
}

// Adds every video in `node` to `out` as [videoId, title]; returns the
// "load more" token if there is one.
function collect(node, out) {
  let token = null;
  const walk = (o) => {
    if (!o || typeof o !== 'object') return;
    const l = o.lockupViewModel;
    if (l?.contentType === 'LOCKUP_CONTENT_TYPE_VIDEO') {
      out.push([l.contentId, l.metadata?.lockupMetadataViewModel?.title?.content ?? '']);
      return;
    }
    const r = o.playlistVideoRenderer; // older page layout
    if (r?.videoId) {
      out.push([r.videoId, (r.title?.runs ?? []).map((x) => x.text).join('')]);
      return;
    }
    if (o.continuationCommand?.token) token = o.continuationCommand.token;
    for (const k in o) walk(o[k]);
  };
  walk(node);
  return token;
}

// Every video in a playlist (100 per page, following "load more").
async function fetchPlaylist(listId) {
  const { data, clientVersion } = await getInitialData(
    `https://www.youtube.com/playlist?list=${listId}&hl=ja`,
  );
  const out = [];
  let token = collect(data.contents, out);
  for (let page = 0; token && page < 50; page++) {
    const res = await fetch('https://www.youtube.com/youtubei/v1/browse?prettyPrint=false', {
      method: 'POST',
      headers: { ...HEADERS, 'content-type': 'application/json' },
      body: JSON.stringify({
        context: { client: { clientName: 'WEB', clientVersion, hl: 'ja', gl: 'JP' } },
        continuation: token,
      }),
    });
    if (!res.ok) throw new Error(`playlist ${listId} page ${page + 2}: HTTP ${res.status}`);
    const j = await res.json();
    token = collect(j.onResponseReceivedActions ?? j, out);
  }
  if (out.length === 0) throw new Error(`playlist ${listId}: no videos found (page layout changed?)`);
  return out;
}

// himehina.jp's tracklists, saved in himehina-site.json -> songKey -> kind
// map, or null if the file is missing or broken (then every song keeps the
// label it had). The site blocks scripts with a bot check, so the file is
// made in a real browser with himehina-site-snippet.js.
const SITE_FILE = 'himehina-site.json';
function readSiteKinds() {
  try {
    const { updated, tracks } = JSON.parse(readFileSync(SITE_FILE, 'utf-8'));
    console.log(`${SITE_FILE}: ${tracks.length} tracks from himehina.jp (saved ${updated})`);
    return addKinds(new Map(), tracks);
  } catch (err) {
    console.warn(`${SITE_FILE}: ${err.message}. Keeping each song's previous original/cover label.`);
    return null;
  }
}

// Channel profile picture, or null (the app falls back to a song thumbnail).
async function fetchAvatar(channelPath) {
  try {
    const { data } = await getInitialData(`https://www.youtube.com/${channelPath}?hl=ja`);
    const url = data.metadata?.channelMetadataRenderer?.avatar?.thumbnails?.[0]?.url;
    return url ? url.replace(/=s\d+-/, '=s176-') : null;
  } catch {
    return null;
  }
}

async function main() {
  const firstRun = !existsSync(OUT);
  const existing = firstRun ? [] : JSON.parse(readFileSync(OUT, 'utf-8'));

  const found = [];
  for (const [kind, id] of Object.entries(sources.channelPlaylists)) {
    const items = await fetchPlaylist(id);
    console.log(`Channel playlist ${kind} (${id}): ${items.length} videos`);
    for (const [videoId, raw] of items) {
      const p = parseChannelTitle(raw);
      if (p) found.push({ videoId, ...p, source: 'channel', kind });
    }
  }
  for (const [singer, channelId] of Object.entries(sources.topicChannels)) {
    // A channel's uploads playlist is its ID with UC -> UU.
    const items = await fetchPlaylist(`UU${channelId.slice(2)}`);
    console.log(`Topic (${singer}): ${items.length} videos`);
    for (const [videoId, raw] of items) {
      const title = parseTopicTitle(raw);
      if (title) found.push({ videoId, title, singer, source: 'topic' });
    }
  }
  for (const m of sources.include ?? []) found.push({ ...m, source: 'manual' });

  const avatars = {
    duo: await fetchAvatar(sources.channel),
    ...Object.fromEntries(
      await Promise.all(
        Object.entries(sources.topicChannels)
          .filter(([singer]) => singer !== 'duo')
          .map(async ([singer, id]) => [singer, await fetchAvatar(`channel/${id}`)]),
      ),
    ),
  };

  const siteKinds = readSiteKinds();
  const tracks = mergeCatalog(found, existing, {
    today: TODAY,
    firstRun,
    exclude: new Set(Object.keys(sources.exclude ?? {})),
    titles: sources.titles ?? {},
    avatars,
    siteKinds,
  });
  const unlabelled = tracks.filter((t) => !t.kind);
  if (unlabelled.length) {
    console.warn(
      `\nNo original/cover label (sources disagree or don't list it), so it's in neither playlist:\n` +
        unlabelled.map((t) => `  ${t.title} (${t.videoId})`).join('\n'),
    );
    // Topic-only songs are labelled only by the site's tracklists.
    if (unlabelled.some((t) => t.source === 'topic')) {
      console.warn(
        `\nA new album or single? Refresh ${SITE_FILE}: open himehina.jp in your browser, ` +
          `paste himehina-site-snippet.js into the console (F12), save the downloaded file ` +
          `over catalog-scraper/${SITE_FILE}, then run npm run himehina again.`,
      );
    }
  }

  // Same loudness pass as scrape.js: only songs without a value yet.
  const todo = tracks.filter((t) => typeof t.loudnessDb !== 'number');
  console.log(`\nFetching loudness for ${todo.length} song(s)...`);
  let ok = 0;
  for (let i = 0; i < todo.length; i += 8) {
    const chunk = todo.slice(i, i + 8);
    const dbs = await Promise.all(chunk.map((t) => fetchLoudnessDb(t.videoId)));
    dbs.forEach((db, j) => {
      if (db !== null) {
        chunk[j].loudnessDb = db;
        ok++;
      }
    });
  }
  console.log(`Loudness: got ${ok}/${todo.length} (missing ones are retried next run).`);

  writeFileSync(OUT, JSON.stringify(tracks, null, 2) + '\n', 'utf-8');
  const fresh = tracks.filter((t) => t.addedAt === TODAY).length;
  console.log(
    `\nWrote ${OUT} with ${tracks.length} songs` +
      (firstRun ? ' (first run: the starting list, nothing marked new).' : ` (+${fresh} new today).`),
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
