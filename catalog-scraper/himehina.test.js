// Checks himehina-core.js on real titles seen on YouTube (2026-10-09).
// Run: npm run test:himehina
import assert from 'node:assert/strict';
import {
  parseChannelTitle,
  parseTopicTitle,
  songKey,
  mergeCatalog,
  htmlToLines,
  parseReleasePage,
  addKinds,
  decideKind,
} from './himehina-core.js';
import { readFileSync } from 'node:fs';

// Channel titles
assert.deepEqual(parseChannelTitle('HIMEHINA『V』MV #ヴィー'), { title: 'V', singer: 'duo' });
assert.deepEqual(parseChannelTitle('HIMEHINA『空っぽの箱庭』MV / 田中ヒメ'), { title: '空っぽの箱庭', singer: 'hime' });
assert.deepEqual(parseChannelTitle('HIMEHINA『Raise your voice!』MV / 鈴木ヒナ'), { title: 'Raise your voice!', singer: 'hina' });
assert.deepEqual(parseChannelTitle('HIMEHINA×AZKi『妄想感傷代償連盟』Cover'), { title: '妄想感傷代償連盟', singer: 'duo' });
assert.deepEqual(parseChannelTitle('HIMEHINA『刀ピークリスマスのテーマソング2022 』Cover【田中ヒメ】'), { title: '刀ピークリスマスのテーマソング2022', singer: 'hime' });
assert.deepEqual(parseChannelTitle('HIMEHINA『劣等上等(Cover)』MV'), { title: '劣等上等', singer: 'duo' });
assert.deepEqual(parseChannelTitle('HIMEHINA『 ヒトガタ 』MV'), { title: 'ヒトガタ', singer: 'duo' });
assert.equal(parseChannelTitle('HIMEHINA『V』Dance Video'), null);
assert.equal(parseChannelTitle('HIMEHINA『キセキ色』ShortMV / 田中ヒメ'), null);
assert.equal(parseChannelTitle('【11/24発売】HIMEHINA Cover ALBUM『ヒメヒナウタミタ弐』【XFD】'), null);

// Topic titles
assert.equal(parseTopicTitle('生と詩'), '生と詩');
assert.equal(parseTopicTitle('天ノ弱 ～Ballade ver.～'), '天ノ弱 ～Ballade ver.～');
assert.equal(parseTopicTitle('藍の華 - Live2022『藍の華』 -'), null);
assert.equal(parseTopicTitle('Int:寝息'), null);
assert.equal(parseTopicTitle('Int：Honey - Live2022『藍の華』 -'), null);
assert.equal(parseTopicTitle('Opening：Remember the Tears - Live2024『涙の薫りがする』 -'), null);
assert.equal(parseTopicTitle('Out:夢の跡'), null);
assert.equal(parseTopicTitle('LADY CRAZY inst.'), null);
assert.equal(parseTopicTitle('琥珀の身体 (Message-In)'), null);

// Keys
assert.equal(songKey('Get Out!!'), songKey('Get out!!'));
assert.equal(songKey('ノンブレス・オブリージュ (HIMEHINA ver.)'), songKey('ノンブレス・オブリージュ'));
assert.notEqual(songKey('天ノ弱 ～Ballade ver.～'), songKey('天ノ弱'));
assert.notEqual(songKey('Raise your voice! ( ver.HIME )'), songKey('Raise your voice!'));
assert.notEqual(songKey('ヒトガタRock'), songKey('ヒトガタ'));

// Merge
const opts = { today: '2026-10-10', firstRun: false, exclude: new Set(['XX']), titles: {}, avatars: {} };
const found = [
  { videoId: 'mv1', title: 'キスキツネ', singer: 'duo', source: 'channel' },
  { videoId: 'tp1', title: 'キスキツネ', singer: 'duo', source: 'topic' },
  { videoId: 'tp2', title: 'キセキ色', singer: 'hime', source: 'topic' },
  { videoId: 'tp3', title: 'Get Out!!', singer: 'hime', source: 'topic' },
  { videoId: 'tp4', title: 'Get out!!', singer: 'hime', source: 'topic' },
  { videoId: 'XX', title: 'hanare-banare', singer: 'hime', source: 'topic' },
];
let out = mergeCatalog(found, [], { ...opts, firstRun: true });
assert.deepEqual(out.map((e) => e.videoId).sort(), ['mv1', 'tp2', 'tp3']);
assert.ok(out.every((e) => e.addedAt === undefined), 'first run: nothing is new');
assert.equal(out.find((e) => e.videoId === 'tp2').artistName, '田中ヒメ');

// Later run: an MV shows up for a song we had as Topic audio, plus one new song.
const later = [
  { videoId: 'mv2', title: 'キセキ色', singer: 'hime', source: 'channel' },
  { videoId: 'tp9', title: '新曲', singer: 'duo', source: 'topic' },
];
const out2 = mergeCatalog(later, out, opts);
assert.deepEqual(out2.map((e) => e.videoId).sort(), ['mv1', 'mv2', 'tp3', 'tp9']);
assert.equal(out2.find((e) => e.videoId === 'mv2').addedAt, undefined, 'replacement is not announced');
assert.equal(out2.find((e) => e.videoId === 'tp9').addedAt, '2026-10-10');
// Songs a run doesn't see are kept.
assert.equal(mergeCatalog([], out2, opts).length, 4);

// himehina.jp discography pages (real lines, 2026-10-12)
assert.deepEqual(
  htmlToLines('<meta content="&lt;div&gt;x&lt;/div&gt;"><style>.a{}</style><div><p>歌：HIMEHINA<br>\n作詞：ゴゴ</p></div>'),
  ['歌：HIMEHINA', '作詞：ゴゴ'],
);
const utamita = ['ALBUM', '2023.11.24 Release', 'ヒメヒナウタミタ弐', '[収録曲]',
  '01. ヒビカセ by れをる/ギガP', '05. 天ノ弱 ～Ballade ver.～ by 164',
  '10. ノンブレス・オブリージュ (HIMEHINA ver.) by ピノキオピー'];
assert.deepEqual(parseReleasePage(utamita).map((t) => t.kind), ['cover', 'cover', 'cover']);
assert.equal(parseReleasePage(utamita)[1].title, '天ノ弱 ～Ballade ver.～');
const solo = ['2026.2.25 Release', 'ふたり紡ぎうた', '01. キセキ色 田中ヒメ(HIMEHINA)',
  '13. Raise your voice!(ヒメVer) 田中ヒメ(HIMEHINA)', '14. 花れ話れ(ヒナVer) 鈴木ヒナ(HIMEHINA)'];
assert.deepEqual(parseReleasePage(solo), [
  { title: 'キセキ色', kind: 'original' },
  { title: 'Raise your voice! ( ver.HIME )', kind: 'original' },
  { title: '花れ話れ ( ver.HINA )', kind: 'original' },
]);
assert.equal(songKey(parseReleasePage(solo)[1].title), songKey('Raise your voice! ( ver.HIME )'));
assert.deepEqual(parseReleasePage(['2024.12.25 Release', 'うたかたよいかないで　～Xmas Version～', 'TRACK', '作詞：ゴゴ']),
  [{ title: 'うたかたよいかないで　～Xmas Version～', kind: 'original' }]);
assert.equal(songKey('うたかたよいかないで　～Xmas Version～'), songKey('うたかたよいかないで ～Xmas Version～'));
assert.deepEqual(parseReleasePage(['2025.3.1 Release', 'HIMEHINA LIVE 2024『涙の薫りがする』', '01. 劣等上等']), []);
assert.deepEqual(parseReleasePage(['no date here', '01. x']), []);

// Original or cover: agree / one knows / disagree
const site = addKinds(new Map(), [{ title: 'テト', kind: 'original' }, { title: 'エゴロック', kind: 'cover' },
  { title: 'X', kind: 'original' }, { title: 'X', kind: 'cover' }]);
const lists = addKinds(new Map(), [{ title: 'エゴロック', kind: 'cover' }, { title: 'KING', kind: 'cover' },
  { title: 'Y', kind: 'original' }]);
assert.equal(decideKind(songKey('テト'), lists, site), 'original');
assert.equal(decideKind(songKey('エゴロック'), lists, site), 'cover');
assert.equal(decideKind(songKey('KING'), lists, null), 'cover');
assert.equal(decideKind(songKey('X'), lists, site), null, 'site conflict');
assert.equal(decideKind(songKey('Y'), lists, addKinds(new Map(), [{ title: 'Y', kind: 'cover' }])), null, 'sources disagree');
assert.equal(decideKind(songKey('unknown'), lists, site), undefined);

// Merge keeps / sets / clears kind
const k1 = mergeCatalog(
  [{ videoId: 'c1', title: 'KING', singer: 'duo', source: 'channel', kind: 'cover' },
   { videoId: 't1', title: 'テト', singer: 'duo', source: 'topic' },
   { videoId: 't2', title: 'Y', singer: 'duo', source: 'topic' }],
  [], { ...opts, siteKinds: site });
const kindOf = (list, id) => list.find((e) => e.videoId === id).kind;
assert.equal(kindOf(k1, 'c1'), 'cover');
assert.equal(kindOf(k1, 't1'), 'original');
assert.equal(kindOf(k1, 't2'), undefined);
const k2 = mergeCatalog([], k1, { ...opts, siteKinds: null }); // site down, nothing found
assert.equal(kindOf(k2, 't1'), 'original', 'old label kept');
const k3 = mergeCatalog([{ videoId: 'c9', title: 'テト', singer: 'duo', source: 'channel', kind: 'cover' }],
  k1, { ...opts, siteKinds: site });
assert.equal(kindOf(k3, 'c9'), undefined, 'disagreement clears the label');

// The browser snippet carries exact copies of the two page parsers.
const snippet = readFileSync(new URL('./himehina-site-snippet.js', import.meta.url), 'utf-8');
for (const fn of [htmlToLines, parseReleasePage]) {
  assert.ok(snippet.includes(fn.toString()), `himehina-site-snippet.js: ${fn.name} differs from himehina-core.js`);
}

console.log('himehina-core: all checks passed');
