/// Unit tests for calibration capture — median thresholds, outlier
/// robustness, and the insufficient-samples guard.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';

void main() {
  group('finalize', () {
    test('steady input yields the expected thresholds', () {
      final capture = CalibrationCapture(squatConfig);
      for (var i = 0; i < 12; i += 1) {
        capture.addSample(kneeAngle: 175);
      }
      final result = capture.finalize();
      expect(result, isNotNull);
      expect(result!.restSignal, closeTo(175, 1e-9));
      expect(result.startDescent, closeTo(163, 1e-9));
      expect(result.enterPeak, closeTo(110, 1e-9));
      expect(result.enterRest, closeTo(150, 1e-9));
      expect(result.romTarget, closeTo(80, 1e-9));
    });

    test('the median absorbs outlier frames', () {
      final capture = CalibrationCapture(squatConfig);
      // 10 steady standing frames plus 2 wild outliers (weight shift).
      for (var i = 0; i < 10; i += 1) {
        capture.addSample(kneeAngle: 174);
      }
      capture.addSample(kneeAngle: 90);
      capture.addSample(kneeAngle: 40);
      final result = capture.finalize();
      // Median of the sorted samples is 174, not dragged by outliers.
      expect(result!.restSignal, closeTo(174, 1e-9));
    });

    test('fewer than minSamples returns null', () {
      final capture = CalibrationCapture(squatConfig);
      for (var i = 0; i < 9; i += 1) {
        capture.addSample(kneeAngle: 175);
      }
      expect(capture.finalize(), isNull);
      // One more sample crosses the floor.
      capture.addSample(kneeAngle: 175);
      expect(capture.finalize(), isNotNull);
    });
  });

  test('sampleCount drives the progress bar', () {
    final capture = CalibrationCapture(squatConfig);
    expect(capture.sampleCount, 0);
    capture.addSample(kneeAngle: 175);
    capture.addSample(kneeAngle: 175);
    expect(capture.sampleCount, 2);
    capture.reset();
    expect(capture.sampleCount, 0);
  });
}
