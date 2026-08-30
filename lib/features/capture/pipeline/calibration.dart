/// Calibration capture (roles.md A-19) — rest-pose samples during the
/// countdown become frozen, athlete-relative thresholds. This is the main
/// defence against camera-angle drift and body proportions.
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'package:reprush/features/capture/pipeline/movement_config.dart';

/// Frozen thresholds derived from the calibrated rest signal.
class CalibrationResult {
  const CalibrationResult({
    required this.restSignal,
    required this.startDescent,
    required this.enterPeak,
    required this.enterRest,
    required this.romTarget,
  });

  /// Median rest-pose knee angle (≈175° standing for squat).
  final double restSignal;

  /// REST → DESCENDING gate: `restSignal + startDescentOffset`.
  final double startDescent;

  /// Valid-depth gate: `restSignal + enterPeakOffset`.
  final double enterPeak;

  /// Return-to-rest gate: `restSignal + enterRestOffset`.
  final double enterRest;

  /// Full ROM target: `restSignal + romTargetOffset`.
  final double romTarget;
}

/// Accumulates rest-pose knee-angle samples and freezes thresholds.
class CalibrationCapture {
  CalibrationCapture(this.config);

  final MovementConfig config;

  final List<double> _samples = [];

  /// Samples collected so far — drives the calibration progress bar.
  int get sampleCount => _samples.length;

  void addSample({required double kneeAngle}) {
    _samples.add(kneeAngle);
  }

  /// Freezes thresholds from the MEDIAN sample — robust to outlier frames
  /// (athlete shifting weight during the countdown). `null` when fewer than
  /// [minSamples] were collected (camera trouble during countdown).
  CalibrationResult? finalize({int minSamples = 10}) {
    if (_samples.length < minSamples) return null;
    final sorted = List<double>.of(_samples)..sort();
    final mid = sorted.length ~/ 2;
    final restSignal = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
    return CalibrationResult(
      restSignal: restSignal,
      startDescent: restSignal + config.startDescentOffset,
      enterPeak: restSignal + config.enterPeakOffset,
      enterRest: restSignal + config.enterRestOffset,
      romTarget: restSignal + config.romTargetOffset,
    );
  }

  void reset() => _samples.clear();
}
