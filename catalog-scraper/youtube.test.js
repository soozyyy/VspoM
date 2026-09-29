// Checks the pure helpers in youtube.js. Run: node youtube.test.js
import assert from 'node:assert/strict';
import { parseDuration, classify, cleanTitle, slugify } from './youtube.js';

assert.equal(parseDuration('PT3M45S'), 225);
assert.equal(parseDuration('PT1H2M'), 3720);
assert.equal(parseDuration('P0D'), 0);

const v = (title, duration, categoryId = '22') => ({ snippet: { title, categoryId }, contentDetails: { duration } });
assert.equal(classify(v('【歌ってみた】少女レイ / 花芽すみれ cover', 'PT4M10S')).song, true);
assert.equal(classify(v('MOMENT RING', 'PT3M50S', '10')).song, true); // Music category, no keyword
assert.equal(classify(v('【歌枠】karaoke!!', 'PT2H')).song, false);
assert.equal(classify(v('少女レイ cover #shorts', 'PT50S')).song, false);
assert.equal(classify(v('【雑談】おはよう', 'PT5M')).reason, 'non-song keyword');
assert.equal(classify(v('APEX ranked', 'PT5M')).reason, 'no song keyword');
assert.equal(classify(v('Discovery vlog', 'PT5M')).song, false); // "cover" inside a word

assert.equal(cleanTitle('【歌ってみた】少女レイ / 花芽すみれ cover'), '少女レイ');
assert.equal(cleanTitle('「ただ君に晴れ」歌ってみた【橘ひなの】'), 'ただ君に晴れ');
assert.equal(cleanTitle('【オリジナル曲】MOMENT RING / 花芽なずな【MV】'), 'MOMENT RING');
assert.equal(cleanTitle('トンデモワンダーズ/ 蝶屋はなび cover'), 'トンデモワンダーズ');
assert.equal(cleanTitle('Bunny Girl (Cover) - Riko Solari'), 'Bunny Girl');
assert.equal(cleanTitle('KING'), 'KING');

assert.equal(slugify('Remia Aotsuki'), 'remia-aotsuki');
assert.equal(slugify(''), '');

console.log('youtube.test.js: all passed');
