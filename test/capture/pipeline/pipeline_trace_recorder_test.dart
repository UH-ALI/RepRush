/// Unit tests for the debug diagnostics recorder — the tuning-evidence
/// log: per-tick dt, raw joint likelihoods, usability flags, and
/// calibration outcomes (accepted AND rejected, with their evidence).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/feedback.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/pipeline_trace_recorder.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

LandmarkFrame _frame(int timestampMs) => LandmarkFrame(
  landmarks: {
    'leftHip': (x: 0, y: 0, likelihood: 0.9),
    'leftKnee': (x: 0, y: 1, likelihood: 0.8),
    'leftAnkle': (x: 0, y: 2, likelihood: 0.7),
    // Right chain intentionally incomplete — presence is not visibility.
    'rightHip': (x: 1, y: 0, likelihood: 0.4),
  },
  timestampMs: timestampMs,
);

PipelineFrame _result({
  String? side = 'left',
  double? raw = 170,
  double? smoothed = 171,
  RepPhase phase = RepPhase.rest,
}) => PipelineFrame(
  repCount: 2,
  shallowAttemptCount: 1,
  phase: phase,
  feedback: const FeedbackSnapshot(level: FeedbackLevel.green, cue: 'Ready'),
  rawAngle: raw,
  smoothedAngle: smoothed,
  justEmitted: null,
  calibrating: false,
  selectedSide: side,
  calibrationProgress: 1,
  leftVisibility: 0.7,
  rightVisibility: null,
  sideSwitched: false,
  lostStreak: side == null ? 3 : 0,
);

void main() {
  test('tick entries carry dt, likelihoods, and usability', () {
    final recorder = PipelineTraceRecorder();
    recorder.recordTick(frame: _frame(1000), result: _result());
    recorder.recordTick(frame: _frame(1066), result: _result());
    recorder.recordTick(
      frame: _frame(1132),
      result: _result(side: null, raw: null, smoothed: null),
    );

    final entries =
        (jsonDecode(recorder.exportJson()) as Map<String, Object?>)['entries']!
            as List<Object?>;
    expect(entries, hasLength(3));

    final first = entries[0]! as Map<String, Object?>;
    expect(first['tMs'], 1000);
    expect(first['dtMs'], isNull); // first entry has no predecessor
    expect(first['usable'], isTrue);
    final joints = first['joints']! as Map<String, Object?>;
    expect(joints['leftKnee'], closeTo(0.8, 1e-9));
    expect(joints['rightKnee'], isNull); // missing landmark stays null
    expect(first['raw'], closeTo(170, 1e-9));
    expect(first['phase'], 'rest');
    expect(first['reps'], 2);
    expect(first['shallow'], 1);

    final second = entries[1]! as Map<String, Object?>;
    expect(second['dtMs'], 66);

    // Selector-null tick: flagged unusable, no angle in the machine.
    final third = entries[2]! as Map<String, Object?>;
    expect(third['usable'], isFalse);
    expect(third['lostStreak'], 3);
    expect(third['raw'], isNull);
  });

  test('an accepted calibration records thresholds and spread', () {
    final recorder = PipelineTraceRecorder();
    recorder.recordCalibration(
      CalibrationAccepted(
        result: CalibrationResult(
          restSignal: 174,
          startDescent: 174 + squatConfig.startDescentOffset,
          enterPeak: 174 + squatConfig.enterPeakOffset,
          enterRest: 174 + squatConfig.enterRestOffset,
          romTarget: 174 + squatConfig.romTargetOffset,
        ),
        spread: 2.5,
      ),
    );
    final entries =
        (jsonDecode(recorder.exportJson()) as Map<String, Object?>)['entries']!
            as List<Object?>;
    final entry = entries.single! as Map<String, Object?>;
    expect(entry['type'], 'calibration');
    expect(entry['result'], 'accepted');
    expect(entry['rest'], closeTo(174, 1e-9));
    expect(entry['spread'], closeTo(2.5, 1e-9));
    final thresholds = entry['thresholds']! as Map<String, Object?>;
    expect(thresholds['enterPeak'], closeTo(109, 1e-9));
  });

  test('a rejected calibration keeps its evidence', () {
    final recorder = PipelineTraceRecorder();
    recorder.recordCalibration(
      const CalibrationRejected(
        reason: CalibrationRejectionReason.unstableRest,
        median: 168,
        spread: 14,
      ),
    );
    final entries =
        (jsonDecode(recorder.exportJson()) as Map<String, Object?>)['entries']!
            as List<Object?>;
    final entry = entries.single! as Map<String, Object?>;
    expect(entry['result'], 'rejected');
    expect(entry['reason'], 'unstableRest');
    expect(entry['median'], closeTo(168, 1e-9));
    expect(entry['spread'], closeTo(14, 1e-9));
  });

  test('clear resets entries and the dt baseline', () {
    final recorder = PipelineTraceRecorder();
    recorder.recordTick(frame: _frame(1000), result: _result());
    recorder.clear();
    expect(recorder.entryCount, 0);
    recorder.recordTick(frame: _frame(5000), result: _result());
    final entries =
        (jsonDecode(recorder.exportJson()) as Map<String, Object?>)['entries']!
            as List<Object?>;
    expect((entries.single! as Map<String, Object?>)['dtMs'], isNull);
  });
}
