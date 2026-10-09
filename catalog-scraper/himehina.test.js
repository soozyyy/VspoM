// Checks himehina-core.js on real titles seen on YouTube (2026-10-09).
// Run: npm run test:himehina
import assert from 'node:assert/strict';
import { parseChannelTitle, parseTopicTitle, songKey, mergeCatalog } from './himehina-core.js';

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

console.log('himehina-core: all checks passed');
