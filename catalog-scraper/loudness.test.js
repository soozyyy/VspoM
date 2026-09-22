// Check for the volume normalizer. Run with: node loudness.test.js
//
// Nothing here is a copy of the shipping logic. The extraction is imported
// from loudness.js; the routing and gain are lifted straight out of the
// injected script in OverlayService.kt. So this cannot drift from what runs
// on the phone.
//
// It is also written to survive TARGET_OFFSET_DB being retuned: the
// assertions are about properties and about the real catalog, not about
// hardcoded numbers that only hold at one offset.
//
// No framework, no fixtures, no network. Exits non-zero on failure.

import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { extractLoudnessDb, readPlayerSource, playerConstants } from './loudness.js';

// --- 1. extraction ---------------------------------------------------------
// Shapes taken from real youtube.com/watch HTML (2026-09-22).

assert.equal(
  extractLoudnessDb('{"audioConfig":{"loudnessDb":7.1399999,"perceptualLoudnessDb":-6.8600001}}'),
  7.14,
  'positive loudness (louder than reference)',
);
assert.equal(
  extractLoudnessDb('{"audioConfig":{"loudnessDb":-5.8199999,"perceptualLoudnessDb":-19.82}}'),
  -5.82,
  'negative loudness (quieter than reference)',
);
assert.equal(
  extractLoudnessDb('{"audioConfig":{"loudnessDb": 0.28999996}}'),
  0.29,
  'whitespace after the colon',
);
assert.equal(
  extractLoudnessDb('<html>no player data here</html>'),
  null,
  'missing field returns null rather than throwing',
);
// If YouTube ever renames the field, this is what fires first — and it fires
// in CI, where you can see it, instead of silently on someone's phone.
assert.equal(
  extractLoudnessDb('{"audioConfig":{"loudnessDB":7.14}}'),
  null,
  'does not match a differently-cased field name',
);

// --- 2. lift the shipping routing and gain ---------------------------------

const { path: kotlinPath, src: kotlin } = readPlayerSource();
const { TARGET_OFFSET_DB, MIN_GAIN, MAX_GAIN } = playerConstants(kotlin);

// Pull a function out by walking braces, so this doesn't depend on how the
// Kotlin file happens to be indented.
function liftFunction(signature) {
  const start = kotlin.indexOf(signature);
  assert.notEqual(start, -1, `could not find "${signature}" in ${kotlinPath}`);
  let depth = 0;
  for (let i = kotlin.indexOf('{', start); i < kotlin.length; i++) {
    if (kotlin[i] === '{') depth++;
    else if (kotlin[i] === '}' && --depth === 0) return kotlin.slice(start, i + 1);
  }
  throw new Error(`unbalanced braces after "${signature}"`);
}

const CONSTS = `var MIN_GAIN=${MIN_GAIN}, MAX_GAIN=${MAX_GAIN}, TARGET_OFFSET_DB=${TARGET_OFFSET_DB};`;
/* eslint-disable no-new-func */
const plan = new Function('db', `${CONSTS} ${liftFunction('function plan(db)')} return plan(db);`);
const boostGain = new Function(
  'target',
  'ytVol',
  `${CONSTS} ${liftFunction('function boostGain(target, ytVol)')} return boostGain(target, ytVol);`,
);

const close = (a, b, msg) =>
  assert.ok(Math.abs(a - b) < 0.01, `${msg} — got ${a}, expected ~${b}`);

// Final level a song reaches, relative to YouTube's reference.
const outputLevel = (db) => {
  const p = plan(db);
  if (p.mode === 'leave') return Math.pow(10, db / 20);
  const applied = p.mode === 'boost' ? boostGain(p.target, 1.0) : p.target;
  return applied * Math.pow(10, db / 20);
};

// --- 3. routing ------------------------------------------------------------
// The point of the design: a song that needs turning DOWN must take the
// 'volume' path, because video.volume does that natively and keeps the audio
// out of the Web Audio render thread — which is what caused the stutter.

assert.equal(plan(TARGET_OFFSET_DB + 6).mode, 'volume', 'louder than target -> video.volume');
assert.equal(plan(TARGET_OFFSET_DB + 0.1).mode, 'volume', 'just above target -> video.volume');
assert.equal(plan(TARGET_OFFSET_DB).mode, 'volume', 'exactly at target needs no boost');
assert.equal(plan(TARGET_OFFSET_DB - 3).mode, 'boost', 'quieter than target -> needs a gain node');

// The single most important case: no catalog value must mean TOUCH NOTHING.
// Applying a target of 1.0 here would overwrite YouTube's own normalization —
// which is the exact bug that caused the original volume problem.
assert.equal(plan(null).mode, 'leave', 'unknown loudness must not touch the element');
assert.equal(plan(NaN).mode, 'leave', 'NaN loudness must not touch the element');
assert.equal(plan(undefined).mode, 'leave', 'missing loudness must not touch the element');

// --- 4. boost gain ---------------------------------------------------------
// YouTube never boosts, so ytVol is 1 on this path in practice...
close(boostGain(1.955, 1.0), 1.955, 'boost applied as-is when YouTube left it alone');
// ...but if YouTube HAD attenuated the element, dividing by ytVol stops us
// stacking a boost on top of that attenuation.
close(boostGain(1.955, 0.5), 3.91, 'boost compensates for YouTube attenuation');
assert.equal(boostGain(99, 1.0), MAX_GAIN, 'absurd boost clamps to MAX_GAIN');
assert.equal(boostGain(0.001, 1.0), MIN_GAIN, 'absurd cut clamps to MIN_GAIN');

// --- 5. the whole point ----------------------------------------------------
// Two songs of very different loudness must come out at the same level.
close(outputLevel(TARGET_OFFSET_DB + 10), outputLevel(TARGET_OFFSET_DB + 1), 'loud and medium end up level');
close(outputLevel(TARGET_OFFSET_DB + 10), outputLevel(TARGET_OFFSET_DB - 3), 'loud and quiet end up level');

// A song too quiet to rescue must land BELOW the others, never above.
const maxBoostDb = 20 * Math.log10(MAX_GAIN);
const tooQuiet = TARGET_OFFSET_DB - maxBoostDb - 4;
assert.ok(
  outputLevel(tooQuiet) < outputLevel(TARGET_OFFSET_DB) - 1e-9,
  'a song past the boost cap plays quiet, never loud',
);

// --- 6. the real catalog ---------------------------------------------------
// Data-driven guard on the offset itself. These encode the decision recorded
// in claude/next-features-plan.md: keep the Web Audio path rare, and keep
// headroom so no real song is too quiet to reach target.

if (existsSync('catalog.json')) {
  const catalog = JSON.parse(readFileSync('catalog.json', 'utf-8'));
  const withLoudness = catalog.filter((s) => typeof s.loudnessDb === 'number');
  assert.ok(withLoudness.length > 0, 'catalog.json has no loudness values — run the scraper');

  const boosted = withLoudness.filter((s) => plan(s.loudnessDb).mode === 'boost');
  const clamped = withLoudness.filter((s) => TARGET_OFFSET_DB - s.loudnessDb > maxBoostDb);

  const pct = (100 * boosted.length) / withLoudness.length;
  assert.ok(
    pct < 5,
    `${pct.toFixed(1)}% of the catalog needs the Web Audio boost path (limit 5%). ` +
      `Lower TARGET_OFFSET_DB (currently ${TARGET_OFFSET_DB}) to bring this down.`,
  );
  assert.equal(
    clamped.length,
    0,
    `${clamped.length} song(s) are too quiet to reach target and will play quiet: ` +
      `${clamped.map((s) => s.title).join(', ')}. Lower TARGET_OFFSET_DB.`,
  );

  const levels = withLoudness.map((s) => outputLevel(s.loudnessDb));
  const spreadDb = 20 * Math.log10(Math.max(...levels) / Math.min(...levels));
  assert.ok(spreadDb < 0.5, `catalog should play level — spread is ${spreadDb.toFixed(2)} dB`);

  console.log(
    `catalog: ${withLoudness.length} songs, ${boosted.length} on the boost path ` +
      `(${pct.toFixed(1)}%), spread ${spreadDb.toFixed(2)} dB`,
  );
}

console.log(`loudness checks passed (target ${TARGET_OFFSET_DB} dB, logic read from ${kotlinPath})`);
