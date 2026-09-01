/// Integration test for the squat pipeline — synthetic landmark traces
/// through the full tick() path, no camera, no ML Kit.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// Builds a frame whose left AND right hip-knee-ankle chains produce the
/// given knee angle: knee at the origin, thigh along +x, shin at [angle].
LandmarkFrame frameAt(
  double angle,
  int timestampMs, {
  double visibility = 0.9,
}) {
  final rad = angle * math.pi / 180;
  final ankle = (
    x: 100 * math.cos(rad),
    y: 100 * math.sin(rad),
    likelihood: visibility,
  );
  const hip = (x: 100.0, y: 0.0, likelihood: 0.9);
  const knee = (x: 0.0, y: 0.0, likelihood: 0.9);
  return LandmarkFrame(
    landmarks: {
      'leftHip': hip,
      'leftKnee': knee,
      'leftAnkle': ankle,
      'rightHip': hip,
      'rightKnee': knee,
      'rightAnkle': ankle,
    },
    timestampMs: timestampMs,
  );
}

List<double> ramp(double from, double to, int steps) => [
  for (var i = 0; i < steps; i += 1) from + (to - from) * i / (steps - 1),
];

/// Like [frameAt] but with independent per-side visibilities, for
/// exercising side-selection stability.
LandmarkFrame frameAtSides(
  double angle,
  int timestampMs, {
  required double left,
  required double right,
}) {
  final rad = angle * math.pi / 180;
  final ankleX = 100 * math.cos(rad);
  final ankleY = 100 * math.sin(rad);
  return LandmarkFrame(
    landmarks: {
      'leftHip': (x: 100.0, y: 0.0, likelihood: left),
      'leftKnee': (x: 0.0, y: 0.0, likelihood: left),
      'leftAnkle': (x: ankleX, y: ankleY, likelihood: left),
      'rightHip': (x: 100.0, y: 0.0, likelihood: right),
      'rightKnee': (x: 0.0, y: 0.0, likelihood: right),
      'rightAnkle': (x: ankleX, y: ankleY, likelihood: right),
    },
    timestampMs: timestampMs,
  );
}

void main() {
  test('ten clean synthetic squats count exactly ten reps', () {
    final pipeline = SquatPipeline(squatConfig);

    // Calibration: 15 steady standing frames, then freeze thresholds.
    var t = 0;
    for (var i = 0; i < 15; i += 1) {
      final result = pipeline.tick(frameAt(175, t));
      expect(result.calibrating, isTrue);
      expect(result.feedback.cue, 'Hold still — calibrating');
      t += 66;
    }
    expect(pipeline.calibrationSampleCount, 15);
    expect(pipeline.finalizeCalibration(), isTrue);

    // Ten reps: 175° → 80° → 175°, fifteen frames each way.
    final cues = <String>[];
    var justCounted = 0;
    for (var rep = 0; rep < 10; rep += 1) {
      for (final angle in ramp(175, 80, 15)) {
        final result = pipeline.tick(frameAt(angle, t));
        cues.add(result.feedback.cue);
        if (result.feedback.repJustCounted) justCounted += 1;
        t += 66;
      }
      for (final angle in ramp(80, 175, 15)) {
        final result = pipeline.tick(frameAt(angle, t));
        cues.add(result.feedback.cue);
        if (result.feedback.repJustCounted) justCounted += 1;
        t += 66;
      }
    }
    // Settle back at standing so the last rep completes.
    for (var i = 0; i < 5; i += 1) {
      final result = pipeline.tick(frameAt(175, t));
      cues.add(result.feedback.cue);
      if (result.feedback.repJustCounted) justCounted += 1;
      t += 66;
    }

    expect(pipeline.repCount, 10);
    expect(pipeline.shallowAttemptCount, 0);
    // Coaching fired during descent and on every counted rep.
    expect(cues, contains('Go lower'));
    expect(cues, contains('Good depth'));
    expect(cues, contains('Stand tall'));
    expect(justCounted, greaterThanOrEqualTo(10));
  });

  test('tracking loss clears the selected side and shows the red cue', () {
    final pipeline = SquatPipeline(squatConfig);
    var t = 0;
    for (var i = 0; i < 15; i += 1) {
      pipeline.tick(frameAt(175, t));
      t += 66;
    }
    expect(pipeline.finalizeCalibration(), isTrue);

    pipeline.tick(frameAt(175, t));
    t += 66;
    // Three unusable frames (visibility below the floor) → red cue.
    PipelineFrame? lost;
    for (var i = 0; i < 3; i += 1) {
      lost = pipeline.tick(frameAt(175, t, visibility: 0.2));
      t += 66;
    }
    expect(lost!.selectedSide, isNull);
    expect(lost.feedback.level, FeedbackLevel.red);
    expect(lost.feedback.cue, 'Tracking lost');
  });

  test(
    'a single spurious usable frame decays, not resets, the lost streak',
    () {
      final pipeline = SquatPipeline(squatConfig);
      var t = 0;
      for (var i = 0; i < 15; i += 1) {
        pipeline.tick(frameAt(175, t));
        t += 66;
      }
      expect(pipeline.finalizeCalibration(), isTrue);

      pipeline.tick(frameAt(175, t)); // steady — streak 0
      t += 66;
      pipeline.tick(frameAt(175, t, visibility: 0.2)); // streak 1
      t += 66;
      final twoLost = pipeline.tick(frameAt(175, t, visibility: 0.2));
      t += 66;
      expect(twoLost.lostStreak, 2);
      expect(twoLost.feedback.cue, isNot('Tracking lost'));

      // One spurious pass-through (stale landmarks skimming the floor)
      // bleeds the streak by one instead of wiping it...
      final spurious = pipeline.tick(frameAt(175, t));
      t += 66;
      expect(spurious.selectedSide, isNotNull);
      expect(spurious.lostStreak, 1);

      // ...so two more unusable frames reach the sustained-loss cue — a
      // hard reset would have needed three more.
      pipeline.tick(frameAt(175, t, visibility: 0.2)); // streak 2
      t += 66;
      final lostCue = pipeline.tick(frameAt(175, t, visibility: 0.2));
      expect(lostCue.lostStreak, 3);
      expect(lostCue.feedback.level, FeedbackLevel.red);
      expect(lostCue.feedback.cue, 'Tracking lost');
    },
  );

  test('a shallow trace counts zero reps and raises the shallow cue', () {
    final pipeline = SquatPipeline(squatConfig);
    var t = 0;
    for (var i = 0; i < 15; i += 1) {
      pipeline.tick(frameAt(175, t));
      t += 66;
    }
    expect(pipeline.finalizeCalibration(), isTrue);

    final cues = <String>[];
    // Descend only to 130° — past startDescent, never past enterPeak (110°).
    for (final angle in ramp(175, 130, 10)) {
      final result = pipeline.tick(frameAt(angle, t));
      cues.add(result.feedback.cue);
      t += 66;
    }
    for (final angle in ramp(130, 175, 10)) {
      final result = pipeline.tick(frameAt(angle, t));
      cues.add(result.feedback.cue);
      t += 66;
    }
    for (var i = 0; i < 5; i += 1) {
      final result = pipeline.tick(frameAt(175, t));
      cues.add(result.feedback.cue);
      t += 66;
    }

    expect(pipeline.repCount, 0);
    expect(pipeline.shallowAttemptCount, 1);
    expect(cues, contains('Not counted — go lower next rep'));
  });

  test('finalize fails gracefully before enough samples', () {
    final pipeline = SquatPipeline(squatConfig);
    for (var i = 0; i < 5; i += 1) {
      pipeline.tick(frameAt(175, i * 66));
    }
    expect(pipeline.finalizeCalibration(), isFalse);
    expect(pipeline.calibrating, isTrue);
  });

  test('reset returns the pipeline to the calibrating phase', () {
    final pipeline = SquatPipeline(squatConfig);
    var t = 0;
    for (var i = 0; i < 15; i += 1) {
      pipeline.tick(frameAt(175, t));
      t += 66;
    }
    expect(pipeline.finalizeCalibration(), isTrue);
    pipeline.reset();
    expect(pipeline.calibrating, isTrue);
    expect(pipeline.repCount, 0);
    expect(pipeline.calibrationSampleCount, 0);
    // Recalibration also clears the frozen thresholds for the next window.
    expect(pipeline.calibration, isNull);
  });

  test('counting frames carry the diagnostics fields', () {
    final pipeline = SquatPipeline(squatConfig);
    var t = 0;
    for (var i = 0; i < 15; i += 1) {
      pipeline.tick(frameAt(175, t));
      t += 66;
    }
    expect(pipeline.finalizeCalibration(), isTrue);

    final frame = pipeline.tick(frameAt(175, t));
    expect(frame.calibration, isNotNull);
    expect(frame.calibration!.restSignal, closeTo(175, 1e-9));
    expect(frame.calibration!.enterPeak, closeTo(110, 1e-9));
    expect(frame.leftVisibility, closeTo(0.9, 1e-9));
    expect(frame.rightVisibility, closeTo(0.9, 1e-9));
    expect(frame.selectedSide, isNotNull);
    expect(frame.sideSwitched, isFalse);
    expect(frame.lostStreak, 0);
    expect(frame.calibrationRejection, isNull);
  });

  test('an unstable calibration window is rejected and re-collected', () {
    final pipeline = SquatPipeline(squatConfig);
    // Alternating 175°/130° frames — weight shifting through the window.
    var t = 0;
    for (var i = 0; i < 16; i += 1) {
      pipeline.tick(frameAt(i.isEven ? 175 : 130, t));
      t += 66;
    }
    expect(pipeline.finalizeCalibration(), isFalse);
    expect(pipeline.calibrating, isTrue);
    // The bad window is cleared for a retry...
    expect(pipeline.calibrationSampleCount, 0);
    // ...and the rejection reason + evidence survive for the HUD/trace.
    final rejected = pipeline.lastCalibrationOutcome! as CalibrationRejected;
    expect(rejected.reason, CalibrationRejectionReason.unstableRest);
    expect(rejected.median, isNotNull);
    expect(rejected.spread, isNotNull);

    final next = pipeline.tick(frameAt(175, t));
    expect(next.calibrationRejection, CalibrationRejectionReason.unstableRest);
  });

  test('an implausible rest angle is rejected with guidance', () {
    final pipeline = SquatPipeline(squatConfig);
    // Calibrating mid-squat: every sample reads a bent knee.
    var t = 0;
    for (var i = 0; i < 16; i += 1) {
      pipeline.tick(frameAt(120, t));
      t += 66;
    }
    expect(pipeline.finalizeCalibration(), isFalse);
    final rejected = pipeline.lastCalibrationOutcome! as CalibrationRejected;
    expect(rejected.reason, CalibrationRejectionReason.implausibleRest);
    expect(pipeline.calibrationSampleCount, 0);
  });

  test('a too-few-samples rejection keeps the collected window', () {
    final pipeline = SquatPipeline(squatConfig);
    for (var i = 0; i < 5; i += 1) {
      pipeline.tick(frameAt(175, i * 66));
    }
    expect(pipeline.finalizeCalibration(), isFalse);
    expect(pipeline.calibrationSampleCount, 5);
    final rejected = pipeline.lastCalibrationOutcome! as CalibrationRejected;
    expect(rejected.reason, CalibrationRejectionReason.tooFewSamples);
  });

  test('the sticky selector does not flicker between near-tied sides', () {
    final pipeline = SquatPipeline(squatConfig);
    // Left slightly stronger on entry...
    var t = 0;
    PipelineFrame result = pipeline.tick(
      frameAtSides(175, t, left: 0.9, right: 0.6),
    );
    t += 66;
    final firstSide = result.selectedSide;
    expect(firstSide, isNotNull);
    for (var i = 0; i < 15; i += 1) {
      pipeline.tick(frameAtSides(175, t, left: 0.9, right: 0.6));
      t += 66;
    }
    expect(pipeline.finalizeCalibration(), isTrue);
    // ...then the other side becomes marginally better (within margin):
    // the counted side must NOT flip frame to frame.
    final flips = <bool>[];
    for (var i = 0; i < 10; i += 1) {
      result = pipeline.tick(
        frameAtSides(
          175,
          t,
          left: firstSide == 'left' ? 0.85 : 0.75,
          right: firstSide == 'left' ? 0.90 : 0.80,
        ),
      );
      flips.add(result.sideSwitched);
      t += 66;
    }
    expect(flips, everyElement(isFalse));
    expect(result.selectedSide, firstSide);
  });
}
