// Check for the volume normalizer. Run with: node loudness.test.js
//
// Two things can silently break it:
//   1. the regex that pulls YouTube's loudness out of a watch page, and
//   2. the gain arithmetic that turns that number into a playback multiplier.
//
// Both are checked against the REAL implementations — (1) by importing
// loudness.js, (2) by lifting computeGain() straight out of the injected
// script in OverlayService.kt. Nothing here is a copy of the logic, so this
// can't drift out of sync with what actually ships.
//
// No framework, no fixtures, no network. Exits non-zero on failure.

import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { extractLoudnessDb } from './loudness.js';

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

// --- 2. gain arithmetic, lifted from the shipping Kotlin --------------------

const KOTLIN_PATHS = [
  '../app/android/app/src/main/kotlin/OverlayService.kt',
  '../app/android/app/src/main/kotlin/com/soozyyy/vspomusic/vspo_music/OverlayService.kt',
];
const kotlinPath = KOTLIN_PATHS.find((p) => existsSync(p));
assert.ok(
  kotlinPath,
  `OverlayService.kt not found. Looked in:\n  ${KOTLIN_PATHS.join('\n  ')}\n` +
    'If the file moved, add its path above — do not delete this check.',
);
const kotlin = readFileSync(kotlinPath, 'utf-8');

// Pull `function computeGain(vol) { ... }` out by walking braces, so this
// doesn't depend on how the Kotlin file happens to be indented.
function liftFunction(source, signature) {
  const start = source.indexOf(signature);
  assert.notEqual(start, -1, `could not find "${signature}" in ${kotlinPath}`);
  let depth = 0;
  for (let i = source.indexOf('{', start); i < source.length; i++) {
    if (source[i] === '{') depth++;
    else if (source[i] === '}' && --depth === 0) return source.slice(start, i + 1);
  }
  throw new Error(`unbalanced braces after "${signature}"`);
}

function liftConst(name) {
  const m = kotlin.match(new RegExp(`var ${name} = (-?[\\d.]+);`));
  assert.ok(m, `could not find "var ${name} = ...;" in ${kotlinPath}`);
  return Number(m[1]);
}

const MIN_GAIN = liftConst('MIN_GAIN');
const MAX_GAIN = liftConst('MAX_GAIN');
const TARGET_OFFSET_DB = liftConst('TARGET_OFFSET_DB');

// eslint-disable-next-line no-new-func
const computeGain = new Function(
  'loudnessDb',
  'vol',
  `var MIN_GAIN = ${MIN_GAIN}, MAX_GAIN = ${MAX_GAIN}, TARGET_OFFSET_DB = ${TARGET_OFFSET_DB};
   ${liftFunction(kotlin, 'function computeGain(vol)')}
   return computeGain(vol);`,
);

const close = (a, b, msg) =>
  assert.ok(Math.abs(a - b) < 0.01, `${msg} — got ${a}, expected ~${b}`);

// Expected values are measured, not invented — see claude/next-features-plan.md,
// Feature 4, for how they were obtained.

// Case A: YouTube DID normalize. Measured in Chrome: a +7.14 dB track plays
// at video.volume 0.44. The two terms cancel, so we must add nothing.
close(computeGain(7.14, 0.44), 1.0, 'loud track, YouTube already levelled it');

// Case B: YouTube did NOT normalize (volume left at 1). We do the whole
// correction ourselves — a loud track gets turned DOWN.
close(computeGain(7.14, 1.0), 0.4395, 'loud track, we level it ourselves');

// Case C: quiet track. YouTube never boosts, so volume stays 1 and the boost
// is entirely ours. Measured: -5.82 dB track, video.volume 1.0.
close(computeGain(-5.82, 1.0), 1.955, 'quiet track gets boosted');

// Case D: a track already at reference needs no change either way.
close(computeGain(0, 1.0), 1.0, 'track at reference');

// Case E: unknown loudness must be a no-op — never a crash, never silence.
assert.equal(computeGain(null, 1.0), 1.0, 'null loudness leaves level alone');
assert.equal(computeGain(NaN, 1.0), 1.0, 'NaN loudness leaves level alone');

// Case F: garbage data stays inside the clamp.
assert.equal(computeGain(-40, 1.0), MAX_GAIN, 'absurdly quiet clamps to MAX_GAIN');
assert.equal(computeGain(40, 1.0), MIN_GAIN, 'absurdly loud clamps to MIN_GAIN');

// Case G: the whole point — the loudest and quietest songs in the real
// catalog must come out at the same level. Catalog values are LUFS; loudnessDb
// is that plus 14 (YouTube's reference).
const outputLevel = (lufs) => {
  const db = lufs + 14;
  return computeGain(db, 1.0) * Math.pow(10, db / 20);
};
close(outputLevel(-6.86), outputLevel(-19.82), 'loudest and quietest end up level');

console.log(`loudness checks passed (gain logic read from ${kotlinPath})`);
