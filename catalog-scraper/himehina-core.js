// The part of himehina.js that decides what is a song and merges the catalog.
// No Node APIs here, so it can be unit-tested (himehina.test.js) and pasted
// into a browser console to check against live YouTube data.

export const SINGERS = {
  duo: { artistName: 'HIMEHINA', artistSlug: 'himehina' },
  hime: { artistName: '田中ヒメ', artistSlug: 'tanaka-hime' },
  hina: { artistName: '鈴木ヒナ', artistSlug: 'suzuki-hina' },
};

// A title from the channel's ORIGINAL MUSIC / COVER MUSIC playlists, e.g.
// 'HIMEHINA×AZKi『妄想感傷代償連盟』Cover' or 'HIMEHINA『空っぽの箱庭』MV / 田中ヒメ'.
// Returns {title, singer}, or null for anything that isn't the full song:
// Dance Videos, solo ShortMVs (the full song comes from Topic instead),
// album crossfade teasers.
export function parseChannelTitle(raw) {
  if (/Dance Video|ShortMV|XFD|Teaser|特報|期間限定/i.test(raw)) return null;
  const m = raw.match(/『(.+?)』/);
  if (!m) return null;
  const title = m[1].replace(/\(\s*Cover\s*\)/i, '').trim();
  const rest = raw.replace(m[0], '');
  const singer = /田中ヒメ/.test(rest) ? 'hime' : /鈴木ヒナ/.test(rest) ? 'hina' : 'duo';
  return { title, singer };
}

// A title from a "- Topic" channel (YouTube's auto-uploads of the released
// albums). Live-album tracks, instrumentals, interludes and the
// "(Message-In)" / "(Laugh-In)" album variants are dropped: same song, not a
// different recording.
export function parseTopicTitle(raw) {
  const t = raw.trim();
  if (/ - Live20\d\d/.test(t)) return null;
  if (/^(Int|Introduction|Opening|Out)\s*[:：]/i.test(t)) return null;
  if (/\binst\.?$/i.test(t)) return null;
  if (/\((Message|Laugh)-In\)/i.test(t)) return null;
  return t;
}

// Same song = same key. Case, width, spaces and punctuation don't count, so
// 'Get Out!!' and 'Get out!!' match. Version suffixes do count
// ('天ノ弱 ～Ballade ver.～', '花れ話れ ( ver.HINA )' are their own songs),
// except '(HIMEHINA ver.)', which is just how the album names their cover.
export function songKey(title) {
  return title
    .normalize('NFKC')
    .toLowerCase()
    .replace(/\(\s*himehina ver\.?\s*\)/g, '')
    .replace(/[\s\p{P}\p{S}]/gu, '');
}

// ---- Original or cover ----
// Two sources, both HIMEHINA's own: which channel playlist a video is in
// (ORIGINAL MUSIC / COVER MUSIC), and the tracklists on himehina.jp's
// discography pages, which credit the original artist on covers
// ('08. エゴロック by すりぃ') and nothing on originals ('14. テト').
// Topic-only songs are only on the site. Nothing is ever guessed: a song
// neither source knows keeps its old label, and a song they disagree on
// gets none.

// A discography page's HTML as trimmed, non-empty text lines.
export function htmlToLines(html) {
  return html
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, '')
    .replace(/<br\s*\/?>|<\/(p|div|li|h\d|dd|dt|tr)>/gi, '\n')
    .replace(/<[^>]+>/g, '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);
}

// One album/single page (from htmlToLines) -> [{title, kind}].
// Albums: numbered tracks, 'by' = cover. Singles have no tracklist: the
// title is the line after '2024.11.15 Release'. Only the album and single
// categories are read (not Blu-ray), and live albums are skipped, since
// setlists list covers without 'by'.
export function parseReleasePage(lines) {
  const r = lines.findIndex((l) => /^\d{4}\.\d{1,2}\.\d{1,2}\s*Release$/i.test(l));
  if (r < 0 || /\bLIVE\b/.test(lines[r + 1] ?? '')) return [];
  const tracks = [];
  for (const l of lines) {
    const m = l.match(/^\d{1,2}\s*[.．]\s*(.+)$/);
    if (!m) continue;
    const [title, by] = m[1].split(/\s+by\s+/i);
    tracks.push({
      title: title
        .replace(/\s+(田中ヒメ|鈴木ヒナ|HIMEHINA)(\s*\(HIMEHINA\))?$/, '')
        .replace(/\(\s*(ヒメ|ヒナ)\s*ver\.?\s*\)/i, (_, who) => ` ( ver.${who === 'ヒメ' ? 'HIME' : 'HINA'} )`),
      kind: by ? 'cover' : 'original',
    });
  }
  if (tracks.length) return tracks;
  return lines[r + 1] ? [{ title: lines[r + 1], kind: 'original' }] : [];
}

// Adds {title, kind} finds to a songKey -> 'original' | 'cover' | 'conflict' map.
export function addKinds(map, finds) {
  for (const { title, kind } of finds) {
    const key = songKey(title);
    if (!key) continue;
    const cur = map.get(key);
    map.set(key, cur && cur !== kind ? 'conflict' : kind);
  }
  return map;
}

// The label for one song: both sources agree, or only one knows. undefined
// = nobody knows (keep the old label); null = they disagree (no label).
export function decideKind(key, playlistKinds, siteKinds) {
  const a = playlistKinds.get(key);
  const b = siteKinds?.get(key);
  if (a === 'conflict' || b === 'conflict' || (a && b && a !== b)) return null;
  return a ?? b;
}

const RANK = { channel: 0, topic: 1, manual: -1 };

/**
 * Merges this run's finds into the existing catalog. One entry per song:
 * a manual include beats a video on their channel, which beats a Topic
 * upload. Songs never disappear just because a run didn't see them.
 *
 * found: [{videoId, title, singer, source, kind?}] in the order they were read
 *        (kind: which channel playlist it came from).
 * existing: the current himehina.json entries ([] on the first run).
 * opts: {today, firstRun, exclude: Set<videoId>, titles: {videoId: title},
 *        avatars: {duo|hime|hina: url},
 *        siteKinds: addKinds() map from himehina.jp, or null if it failed}
 */
export function mergeCatalog(found, existing, opts) {
  const { today, firstRun, exclude, titles, avatars, siteKinds = null } = opts;
  const singerOf = (e) =>
    Object.keys(SINGERS).find((k) => SINGERS[k].artistSlug === e.artistSlug) ?? 'duo';
  const candidates = [
    // Existing first, so on a tie the song keeps the videoId it already has
    // (playlists store videoIds).
    ...existing.map((e) => ({ ...e, singer: singerOf(e), source: e.source ?? 'channel', old: e })),
    ...found,
  ].filter((c) => !exclude.has(c.videoId));
  const playlistKinds = addKinds(
    new Map(),
    found
      .filter((c) => c.kind && !exclude.has(c.videoId))
      .map((c) => ({ title: titles[c.videoId] ?? c.title, kind: c.kind })),
  );

  const best = new Map(); // key -> candidate
  const oldByKey = new Map(); // key -> existing entry with that key
  for (const c of candidates) {
    const title = titles[c.videoId] ?? c.title;
    const key = songKey(title);
    if (!key) continue;
    if (c.old && !oldByKey.has(key)) oldByKey.set(key, c.old);
    const cur = best.get(key);
    if (!cur || RANK[c.source] < RANK[cur.source]) best.set(key, { ...c, title });
  }

  const out = [];
  for (const [key, c] of best) {
    const s = SINGERS[c.singer] ?? SINGERS.duo;
    const entry = {
      ...(c.old ?? {}),
      videoId: c.videoId,
      title: c.title,
      artistName: s.artistName,
      artistSlug: s.artistSlug,
      thumbnail: `https://i.ytimg.com/vi/${c.videoId}/maxresdefault.jpg`,
      artistAvatarUrl: avatars[c.singer] ?? c.old?.artistAvatarUrl ?? null,
      source: c.source,
    };
    const prev = oldByKey.get(key);
    const kind = decideKind(key, playlistKinds, siteKinds);
    const finalKind = kind === undefined ? (c.old ?? prev)?.kind : kind;
    if (finalKind) entry.kind = finalKind;
    else delete entry.kind;
    if (!c.old) {
      // A better version of a song we already had (e.g. an MV replacing the
      // Topic audio) keeps the old date, so it isn't announced as new again.
      // The first run is the starting list: nothing in it is "new".
      const addedAt = prev ? prev.addedAt : firstRun ? undefined : today;
      if (addedAt) entry.addedAt = addedAt;
      else delete entry.addedAt;
      delete entry.loudnessDb; // belongs to the old video
    }
    out.push(entry);
  }
  return out.sort(
    (a, b) => a.artistName.localeCompare(b.artistName) || a.title.localeCompare(b.title),
  );
}
