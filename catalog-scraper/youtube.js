// Builds the song catalog straight from YouTube, replacing the vspodex.app
// scrape (Cloudflare now blocks it from GitHub's servers).
//
//   members: Holodex  GET /api/v2/channels?org=VSpo   (JP + EN, new debuts
//            appear automatically) + any channel already in catalog.json
//            (e.g. the official ぶいすぽっ！ channel)
//   songs:   YouTube Data API v3 — every upload of every member, then the
//            rules in classify() decide what counts as a song
//
// REPORT-ONLY for now: writes catalog.candidate.json, members.json and
// report.md next to this file. It never touches catalog.json.
//
// Env: YOUTUBE_API_KEY, HOLODEX_API_KEY (GitHub secrets).
//      MAX_PAGES=N limits uploads read per channel (50 per page) — unset = all.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const YT = 'https://www.googleapis.com/youtube/v3';
const MIN_SECONDS = 60; // Shorts / teasers below this
const MAX_SECONDS = 600; // streams, medleys-as-streams, vlogs above this

// A title (or category Music) must look like a song...
const SONG_RE =
  /歌ってみた|歌わせて|オリジナル曲|オリジナルソング|original\s*song|\bcover(ed)?\b|\bMV\b|music\s*video|official\s*audio|feat\.|ft\./i;
// ...and must not look like one of these music-adjacent non-songs.
const NOT_SONG_RE =
  /歌枠|karaoke|カラオケ|切り抜き|\bclip\b|#shorts|\bshorts\b|クロスフェード|\bxfd\b|crossfade|teaser|trailer|ティザー|ダイジェスト|digest|告知|予告|配信|雑談/i;

// ---------- pure helpers (tested in youtube.test.js) ----------

export function parseDuration(iso) {
  const m = /^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/.exec(iso || '');
  if (!m) return 0;
  const [, d = 0, h = 0, min = 0, s = 0] = m.map((x) => Number(x) || 0);
  return d * 86400 + h * 3600 + min * 60 + s;
}

// -> { song: true } or { song: false, reason }
export function classify(v) {
  const title = v.snippet?.title || '';
  const secs = parseDuration(v.contentDetails?.duration);
  if (NOT_SONG_RE.test(title)) return { song: false, reason: 'non-song keyword' };
  if (secs < MIN_SECONDS) return { song: false, reason: `too short (${secs}s)` };
  if (secs > MAX_SECONDS) return { song: false, reason: `too long (${secs}s)` };
  const music = v.snippet?.categoryId === '10';
  if (!music && !SONG_RE.test(title)) return { song: false, reason: 'no song keyword' };
  return { song: true };
}

// "【歌ってみた】少女レイ / 花芽すみれ cover" -> "少女レイ"
// ponytail: regex heuristic; bad titles get fixed via overrides.json later.
export function cleanTitle(raw) {
  const quoted = /[「『]([^」』]+)[」』]/.exec(raw);
  if (quoted) return quoted[1].trim();
  let t = raw
    .replace(/【[^】]*】|\[[^\]]*\]|［[^］]*］/g, ' ')
    .replace(/[（(][^）)]*(cover|歌ってみた|mv|music video|official|feat|ft\.)[^）)]*[）)]/gi, ' ')
    .replace(/#\S+/g, ' ');
  t = t.split(/\s*[/／|｜]\s*|\s-\s/).find((part) => part.trim()) || t;
  t = t
    .replace(/歌ってみた|歌わせていただきました|\bcover(ed)?\b|\bMV\b|music\s*video|official\s*audio|オリジナル曲|original\s*song/gi, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  return t || raw.trim();
}

export function slugify(name) {
  return (name || '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

// ---------- API ----------

let quota = 0;

async function yt(endpoint, params) {
  const url = new URL(`${YT}/${endpoint}`);
  for (const [k, v] of Object.entries({ ...params, key: process.env.YOUTUBE_API_KEY })) {
    url.searchParams.set(k, v);
  }
  quota += 1; // every list call we use costs 1 unit
  const res = await fetch(url);
  const body = await res.json();
  if (!res.ok) throw new Error(`YouTube ${endpoint} ${res.status}: ${body.error?.message}`);
  return body;
}

async function holodexChannels() {
  const all = [];
  for (let offset = 0; ; offset += 50) {
    const res = await fetch(
      `https://holodex.net/api/v2/channels?org=VSpo&type=vtuber&limit=50&offset=${offset}`,
      { headers: { 'X-APIKEY': process.env.HOLODEX_API_KEY } }
    );
    if (!res.ok) throw new Error(`Holodex ${res.status}: ${await res.text()}`);
    const page = await res.json();
    all.push(...page);
    if (page.length < 50) return all;
  }
}

async function videosById(ids) {
  const out = [];
  for (let i = 0; i < ids.length; i += 50) {
    const body = await yt('videos', {
      part: 'snippet,contentDetails',
      id: ids.slice(i, i + 50).join(','),
      maxResults: 50,
    });
    out.push(...body.items);
  }
  return out;
}

async function channelsById(ids) {
  const out = [];
  for (let i = 0; i < ids.length; i += 50) {
    const body = await yt('channels', {
      part: 'snippet,contentDetails',
      id: ids.slice(i, i + 50).join(','),
      maxResults: 50,
    });
    out.push(...body.items);
  }
  return out;
}

async function uploadIds(playlistId, maxPages) {
  const ids = [];
  let pageToken;
  for (let page = 0; page < maxPages; page++) {
    const body = await yt('playlistItems', {
      part: 'contentDetails',
      playlistId,
      maxResults: 50,
      ...(pageToken && { pageToken }),
    });
    ids.push(...body.items.map((it) => it.contentDetails.videoId));
    pageToken = body.nextPageToken;
    if (!pageToken) break;
  }
  return ids;
}

const bestThumb = (t = {}) => (t.maxres || t.standard || t.high || t.medium || t.default || {}).url;

// ---------- main ----------

async function main() {
  for (const k of ['YOUTUBE_API_KEY', 'HOLODEX_API_KEY']) {
    if (!process.env[k]) throw new Error(`${k} is not set`);
  }
  const maxPages = Number(process.env.MAX_PAGES) || Infinity;
  const existing = existsSync('catalog.json') ? JSON.parse(readFileSync('catalog.json', 'utf-8')) : [];
  console.log(`catalog.json: ${existing.length} tracks`);

  // 1. Existing tracks -> which channel each is on -> channelId => vspodex slug.
  const existingVideos = await videosById(existing.map((t) => t.videoId));
  const channelOfVideo = new Map(existingVideos.map((v) => [v.id, v.snippet.channelId]));
  const slugOfChannel = new Map();
  for (const t of existing) {
    const ch = channelOfVideo.get(t.videoId);
    if (ch && t.artistSlug && !slugOfChannel.has(ch)) slugOfChannel.set(ch, t.artistSlug);
  }

  // 2. Members = Holodex VSpo channels + any channel already in the catalog.
  const holo = await holodexChannels();
  console.log(`Holodex: ${holo.length} VSpo channels`);
  const holoById = new Map(holo.map((c) => [c.id, c]));
  const channelIds = [...new Set([...holo.map((c) => c.id), ...slugOfChannel.keys()])];
  const channels = await channelsById(channelIds);

  const members = channels.map((c) => {
    const h = holoById.get(c.id);
    return {
      channelId: c.id,
      name: c.snippet.title,
      slug: slugOfChannel.get(c.id) || slugify(h?.english_name) || slugify(c.snippet.title) || c.id,
      slugSource: slugOfChannel.has(c.id) ? 'catalog' : 'generated',
      branch: /EN/i.test(h?.suborg || '') || /VSPO!? ?EN/i.test(c.snippet.title) ? 'EN' : 'JP',
      inHolodex: !!h,
      inactive: !!h?.inactive,
      avatar: bestThumb(c.snippet.thumbnails),
      uploads: c.contentDetails.relatedPlaylists.uploads,
    };
  });

  // 3. Every upload of every member, then classify.
  const verdicts = new Map(); // videoId -> { video, member, song, reason }
  for (const m of members) {
    const ids = await uploadIds(m.uploads, maxPages);
    const vids = await videosById(ids);
    let songs = 0;
    for (const v of vids) {
      const c = classify(v);
      if (c.song) songs++;
      if (!verdicts.has(v.id) || c.song) verdicts.set(v.id, { video: v, member: m, ...c });
    }
    m.uploadsScanned = vids.length;
    m.songs = songs;
    console.log(`${m.name}: ${vids.length} uploads, ${songs} songs`);
  }

  // 4. Candidate catalog: keep every existing track as-is, add new songs.
  const known = new Set(existing.map((t) => t.videoId));
  const added = [];
  for (const [id, r] of verdicts) {
    if (!r.song || known.has(id)) continue;
    added.push({
      videoId: id,
      title: cleanTitle(r.video.snippet.title),
      artistName: r.member.name,
      artistSlug: r.member.slug,
      thumbnail: bestThumb(r.video.snippet.thumbnails),
      artistAvatarUrl: r.member.avatar,
      _rawTitle: r.video.snippet.title, // report only
    });
  }
  const candidate = [...existing, ...added.map(({ _rawTitle, ...t }) => t)];

  // 5. Recall against the vspodex-derived catalog.
  const missed = existing
    .filter((t) => !verdicts.get(t.videoId)?.song)
    .map((t) => {
      const r = verdicts.get(t.videoId);
      let why = r?.reason;
      if (!r) why = channelOfVideo.has(t.videoId) ? 'not in a scanned channel / page limit' : 'video gone';
      return { ...t, why, raw: r?.video.snippet.title ?? '', secs: parseDuration(r?.video.contentDetails.duration) };
    });
  const found = existing.length - missed.length;

  writeFileSync('catalog.candidate.json', JSON.stringify(candidate, null, 2));
  writeFileSync(
    'members.json',
    JSON.stringify(members.map(({ uploads, uploadsScanned, songs, ...m }) => m), null, 2)
  );

  const esc = (s) => String(s ?? '').replace(/\|/g, '\\|');
  const reasons = {};
  for (const m of missed) reasons[m.why] = (reasons[m.why] || 0) + 1;
  const report = [
    '# YouTube catalog test report',
    '',
    `- Recall: **${found} / ${existing.length}** current songs found (${((found / existing.length) * 100).toFixed(1)}%)`,
    `- New songs found: **${added.length}**`,
    `- Candidate total: ${candidate.length}`,
    `- YouTube quota used: ~${quota} units (of 10,000/day)`,
    '',
    '## Missed current songs, by reason',
    ...Object.entries(reasons).map(([r, n]) => `- ${r}: ${n}`),
    '',
    '| videoId | artist | catalog title | YouTube title | length | reason |',
    '|---|---|---|---|---|---|',
    ...missed.map((m) => `| ${m.videoId} | ${esc(m.artistName)} | ${esc(m.title)} | ${esc(m.raw)} | ${m.secs}s | ${m.why} |`),
    '',
    '## New songs (check for false positives + title cleanup)',
    '| videoId | artist | cleaned title | YouTube title |',
    '|---|---|---|---|',
    ...added.map((a) => `| ${a.videoId} | ${esc(a.artistName)} | ${esc(a.title)} | ${esc(a._rawTitle)} |`),
    '',
    '## Members',
    '| name | slug | slug from | branch | Holodex | inactive | uploads scanned | songs |',
    '|---|---|---|---|---|---|---|---|',
    ...members.map(
      (m) => `| ${esc(m.name)} | ${m.slug} | ${m.slugSource} | ${m.branch} | ${m.inHolodex ? 'yes' : 'no'} | ${m.inactive ? 'yes' : ''} | ${m.uploadsScanned} | ${m.songs} |`
    ),
    '',
  ].join('\n');
  writeFileSync('report.md', report);
  console.log(`\nRecall ${found}/${existing.length}, ${added.length} new, quota ~${quota}. See report.md.`);
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
