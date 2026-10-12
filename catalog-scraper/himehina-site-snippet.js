// Makes catalog-scraper/himehina-site.json: the original/cover tracklists from
// himehina.jp's discography. The site blocks scripts with a bot check, so this
// runs in a normal browser:
//   1. Open https://himehina.jp in Chrome, press F12, go to Console.
//   2. Paste this whole file and press Enter. It reads every album and single
//      page (about 40, takes a few seconds) and downloads himehina-site.json.
//   3. Move that file over catalog-scraper/himehina-site.json, then run
//      npm run himehina and commit both JSON files.
// Do it after HIMEHINA release a new album or single: npm run himehina says so
// when a Topic song has no label.
//
// The two functions are exact copies of himehina-core.js; himehina.test.js
// fails if they drift apart.

function htmlToLines(html) {
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

function parseReleasePage(lines) {
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

(async () => {
  const ids = new Set();
  for (const cat of ['album', 'single']) {
    // 9 releases per listing page; stop at the first page with nothing new.
    for (let page = 1; page <= 30; page++) {
      const html = await (await fetch(`/discography/category/${cat}?page=${page}`)).text();
      const before = ids.size;
      for (const m of html.matchAll(/\/discography\/(discography-\d+)/g)) ids.add(m[1]);
      if (ids.size === before) break;
    }
  }
  if (ids.size === 0) throw new Error('No releases found. Is this tab on himehina.jp?');
  const tracks = [];
  for (const id of ids) {
    const html = await (await fetch(`/discography/${id}`)).text();
    tracks.push(...parseReleasePage(htmlToLines(html)));
  }
  const json = JSON.stringify(
    { updated: new Date().toLocaleDateString('sv'), releases: ids.size, tracks },
    null,
    2,
  );
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([json + '\n'], { type: 'application/json' }));
  a.download = 'himehina-site.json';
  a.click();
  console.log(`himehina-site.json: ${ids.size} releases, ${tracks.length} tracks. Check your Downloads.`);
})();
