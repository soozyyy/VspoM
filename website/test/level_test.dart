import 'package:flutter_test/flutter_test.dart';
import 'package:vspom_web/level.dart';

void main() {
  test('levelFactor brings every song to the -6 dB target', () {
    // Loud: YouTube takes it to reference, we take it 6 dB further.
    expect(levelFactor(7.14), closeTo(0.501, 0.001));
    expect(levelFactor(null), closeTo(0.501, 0.001));
    // Quieter than reference but louder than target: turned down a bit.
    expect(levelFactor(-3), closeTo(0.708, 0.001));
    // Quieter than target: can't be boosted, so full volume.
    expect(levelFactor(-9.45), 1.0);
  });
}
