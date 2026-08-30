/// Unit tests for the EMA smoother.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/ema_filter.dart';

void main() {
  test('the first sample passes through unfiltered', () {
    final ema = EmaFilter(alpha: 0.35);
    expect(ema.update(175), 175);
  });

  test('a step input converges towards the new level', () {
    final ema = EmaFilter(alpha: 0.35);
    ema.update(175);
    var smoothed = ema.update(80);
    expect(smoothed, lessThan(175));
    expect(smoothed, greaterThan(80));
    // Keep stepping — the filter approaches 80 asymptotically.
    for (var i = 0; i < 30; i += 1) {
      smoothed = ema.update(80);
    }
    expect(smoothed, closeTo(80, 0.5));
  });

  test('reset clears state — next sample passes through raw', () {
    final ema = EmaFilter(alpha: 0.35);
    ema.update(175);
    ema.update(80);
    ema.reset();
    expect(ema.update(120), 120);
  });

  test('alpha = 1.0 passes raw values straight through', () {
    final ema = EmaFilter(alpha: 1.0);
    ema.update(175);
    expect(ema.update(80), 80);
    expect(ema.update(110), 110);
  });
}
