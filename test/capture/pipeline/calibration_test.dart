/// Unit tests for calibration capture — median thresholds, outlier
/// robustness, stability/plausibility validation, and the
/// insufficient-samples guard.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';

void main() {
  group('attemptFinalize', () {
    test('steady input yields the expected thresholds', () {
      final capture = CalibrationCapture(squatConfig);
      for (var i = 0; i < 12; i += 1) {
        capture.addSample(signal: 175);
      }
      final outcome = capture.attemptFinalize();
      final accepted = outcome as CalibrationAccepted;
      expect(accepted.result.restSignal, closeTo(175, 1e-9));
      expect(accepted.result.startDescent, closeTo(163, 1e-9));
      expect(accepted.result.enterPeak, closeTo(110, 1e-9));
      expect(accepted.result.enterRest, closeTo(150, 1e-9));
      expect(accepted.result.romTarget, closeTo(80, 1e-9));
      expect(accepted.spread, closeTo(0, 1e-9));
    });

    test('the median absorbs mild outlier frames', () {
      final capture = CalibrationCapture(squatConfig);
      // 10 steady standing frames plus 2 small weight shifts.
      for (var i = 0; i < 10; i += 1) {
        capture.addSample(signal: 174);
      }
      capture.addSample(signal: 168);
      capture.addSample(signal: 170);
      final accepted = capture.attemptFinalize() as CalibrationAccepted;
      // Median of the sorted samples is 174, not dragged by the shifts.
      expect(accepted.result.restSignal, closeTo(174, 1e-9));
    });

    test('an unstable window is rejected with its evidence', () {
      final capture = CalibrationCapture(squatConfig);
      // Athlete shifting weight through the countdown: wild swing.
      for (var i = 0; i < 10; i += 1) {
        capture.addSample(signal: 174);
      }
      capture.addSample(signal: 90);
      capture.addSample(signal: 40);
      final rejected = capture.attemptFinalize() as CalibrationRejected;
      expect(rejected.reason, CalibrationRejectionReason.unstableRest);
      // The evidence survives the rejection for the diagnostics trace.
      expect(rejected.median, closeTo(174, 1e-9));
      expect(rejected.spread, isNotNull);
      expect(rejected.spread!, greaterThan(CalibrationGuards.maxRestSpread));
    });

    test('an implausibly low rest angle is rejected', () {
      final capture = CalibrationCapture(squatConfig);
      // Calibrated mid-squat — the frozen thresholds would be biased low.
      for (var i = 0; i < 12; i += 1) {
        capture.addSample(signal: 120);
      }
      final rejected = capture.attemptFinalize() as CalibrationRejected;
      expect(rejected.reason, CalibrationRejectionReason.implausibleRest);
      expect(rejected.median, closeTo(120, 1e-9));
    });

    test('an implausibly high rest angle is rejected', () {
      final capture = CalibrationCapture(squatConfig);
      for (var i = 0; i < 12; i += 1) {
        capture.addSample(signal: 190);
      }
      final rejected = capture.attemptFinalize() as CalibrationRejected;
      expect(rejected.reason, CalibrationRejectionReason.implausibleRest);
    });

    test('fewer than minSamples keeps the samples and reports why', () {
      final capture = CalibrationCapture(squatConfig);
      for (var i = 0; i < 9; i += 1) {
        capture.addSample(signal: 175);
      }
      final rejected = capture.attemptFinalize() as CalibrationRejected;
      expect(rejected.reason, CalibrationRejectionReason.tooFewSamples);
      expect(rejected.median, isNull);
      // The samples survive a too-few rejection — collection continues.
      expect(capture.sampleCount, 9);
      capture.addSample(signal: 175);
      expect(capture.attemptFinalize(), isA<CalibrationAccepted>());
    });

    test('attemptFinalize never mutates the sample buffer', () {
      final capture = CalibrationCapture(squatConfig);
      for (var i = 0; i < 12; i += 1) {
        capture.addSample(signal: 175);
      }
      capture.attemptFinalize();
      expect(capture.sampleCount, 12);
    });
  });

  test('sampleCount drives the progress bar', () {
    final capture = CalibrationCapture(squatConfig);
    expect(capture.sampleCount, 0);
    capture.addSample(signal: 175);
    capture.addSample(signal: 175);
    expect(capture.sampleCount, 2);
    capture.reset();
    expect(capture.sampleCount, 0);
  });
}
