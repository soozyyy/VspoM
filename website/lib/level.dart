import 'dart:math';

/// Target level in dB relative to YouTube's loudness reference. Same -6 as
/// the app (TARGET_OFFSET_DB in OverlayService.kt), so songs sound the same
/// on both.
const targetOffsetDb = -6.0;

/// Player volume (0..1, before the listener's own volume) that brings a song
/// with YouTube's [loudnessDb] to the target level.
///
/// YouTube's player already turns loud songs (loudnessDb > 0) down to its
/// reference and never turns quiet ones up (measured on youtube.com, see
/// next-features-plan.md Feature 4), so this only adds what's left. A song
/// quieter than the target would need more than full volume, which a player
/// volume can't give, so it plays at full volume, a bit quiet (2 songs).
/// Unknown loudness is treated as "YouTube levels it", the common case.
// ponytail: assumes the embedded player normalizes like youtube.com does;
// not measured for embeds. If loud songs sound louder than quiet ones on the
// website, measure video.volume in the embed and adjust here.
double levelFactor(double? loudnessDb) {
  final db = loudnessDb ?? 0;
  final want = pow(10, (targetOffsetDb - db) / 20);
  final youtube = db > 0 ? pow(10, -db / 20) : 1;
  return min(1.0, want / youtube).toDouble();
}
