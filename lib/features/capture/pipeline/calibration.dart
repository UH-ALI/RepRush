/// Calibration capture (roles.md A-19) — rest-pose samples during the
/// countdown become frozen, athlete-relative thresholds. This is the main
/// defence against camera-angle drift and body proportions.
///
/// The quality layer on top: a finalize attempt is VALIDATED before its
/// thresholds freeze — the median must be a plausible standing angle and
/// the samples must be stable (median + spread). A rejected attempt reports
/// why and hands its evidence (median, spread) to the diagnostics trace
/// before the samples are cleared for retry.
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'package:reprush/features/capture/pipeline/movement_config.dart';

/// Validation guards for the rest-pose calibration. These are QUALITY
/// gates for the calibration window, not counting thresholds — the
/// production counting values live in [squatConfig] and stay untouched.
/// Grouped here in one place so tuning happens against measured
/// diagnostics, never against guesses.
abstract final class CalibrationGuards {
  /// A standing-straight knee angle reads ~165–180°. Below the floor the
  /// athlete was mid-squat / knees bent; the frozen thresholds would be
  /// biased low and "Go lower" would fire on honest depth.
  static const double minRestAngle = 145;

  /// Geometric maximum is 180°; a small margin absorbs landmark jitter.
  static const double maxRestAngle = 184;

  /// Maximum allowed p10→p90 spread of the calibration samples. Above
  /// this the athlete was shifting weight — the median is unreliable.
  static const double maxRestSpread = 8;

  /// The quantile band used to measure spread (robust to the 1–2 outlier
  /// frames the median already absorbs).
  static const double spreadLowQuantile = 0.1;
  static const double spreadHighQuantile = 0.9;
}

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

/// Why a calibration attempt was rejected — drives the retry messaging.
enum CalibrationRejectionReason { tooFewSamples, unstableRest, implausibleRest }

/// The outcome of one finalize attempt. Rejections carry the measured
/// median/spread so the diagnostics trace keeps the evidence even after
/// the samples are cleared for retry.
sealed class CalibrationOutcome {
  const CalibrationOutcome();
}

final class CalibrationAccepted extends CalibrationOutcome {
  const CalibrationAccepted({required this.result, required this.spread});

  final CalibrationResult result;

  /// Measured p10→p90 spread of the accepted samples.
  final double spread;
}

final class CalibrationRejected extends CalibrationOutcome {
  const CalibrationRejected({required this.reason, this.median, this.spread});

  final CalibrationRejectionReason reason;

  /// Measured evidence for the rejection — null only when there were not
  /// enough samples to measure anything.
  final double? median;
  final double? spread;
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

  /// Validates the collected samples and, when they pass, freezes
  /// thresholds from the MEDIAN sample — robust to outlier frames
  /// (athlete shifting weight during the countdown).
  ///
  /// Pure: never mutates the sample buffer — the caller decides whether a
  /// rejection clears it (retry) or keeps it (keep collecting).
  CalibrationOutcome attemptFinalize({int minSamples = 10}) {
    if (_samples.length < minSamples) {
      return const CalibrationRejected(
        reason: CalibrationRejectionReason.tooFewSamples,
      );
    }
    final sorted = List<double>.of(_samples)..sort();
    final median = _medianOf(sorted);
    final spread = _spreadOf(sorted);
    if (median < CalibrationGuards.minRestAngle ||
        median > CalibrationGuards.maxRestAngle) {
      return CalibrationRejected(
        reason: CalibrationRejectionReason.implausibleRest,
        median: median,
        spread: spread,
      );
    }
    if (spread > CalibrationGuards.maxRestSpread) {
      return CalibrationRejected(
        reason: CalibrationRejectionReason.unstableRest,
        median: median,
        spread: spread,
      );
    }
    return CalibrationAccepted(
      result: CalibrationResult(
        restSignal: median,
        startDescent: median + config.startDescentOffset,
        enterPeak: median + config.enterPeakOffset,
        enterRest: median + config.enterRestOffset,
        romTarget: median + config.romTargetOffset,
      ),
      spread: spread,
    );
  }

  void reset() => _samples.clear();

  static double _medianOf(List<double> sorted) {
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /// Range across the central quantile band of [sorted] — robust to the
  /// 1–2 wild frames at either end.
  static double _spreadOf(List<double> sorted) {
    final lo = (sorted.length * CalibrationGuards.spreadLowQuantile)
        .floor()
        .clamp(0, sorted.length - 1);
    final hi = (sorted.length * CalibrationGuards.spreadHighQuantile)
        .floor()
        .clamp(0, sorted.length - 1);
    return sorted[hi] - sorted[lo];
  }
}
