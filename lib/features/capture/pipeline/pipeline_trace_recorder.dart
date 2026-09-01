/// Debug-only pipeline diagnostics recorder — per-tick measurements that
/// the landmark [TraceRecorder] cannot see: raw/smoothed angle, phase,
/// thresholds, side selection, per-joint likelihoods, and per-tick dt.
/// This is the tuning-evidence log: replay fixtures come from landmarks,
/// threshold decisions come from here.
///
/// Strictly local: never submitted, uploaded, or included in Evidence.
/// Enabled only in debug builds by the controller.
///
/// Ownership: A. Purity rule: plain Dart only (`dart:convert` allowed).
library;

import 'dart:convert';

import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// The six squat-chain joints whose raw likelihoods are logged — presence
/// is not visibility, so the trace carries the likelihood values, not a
/// boolean.
const _squatJoints = [
  'leftHip',
  'leftKnee',
  'leftAnkle',
  'rightHip',
  'rightKnee',
  'rightAnkle',
];

class PipelineTraceRecorder {
  final List<Map<String, Object?>> _entries = [];
  int? _lastTimestampMs;

  int get entryCount => _entries.length;

  /// One pipeline tick. Entries carry per-tick dt so frame-pacing issues
  /// (thermal throttling, camera stalls) show up as a distribution, not a
  /// single averaged fps number.
  void recordTick({
    required LandmarkFrame frame,
    required PipelineFrame result,
  }) {
    final previous = _lastTimestampMs;
    _lastTimestampMs = frame.timestampMs;
    final resultPhase = result.phase;
    _entries.add({
      'type': 'tick',
      'tMs': frame.timestampMs,
      'dtMs': previous == null ? null : frame.timestampMs - previous,
      // Selector-null frame: no angle ever reaches the state machine
      // (never holds-last, never feeds garbage) — flag it so a mid-rep
      // dropout is visible instead of a mysteriously missed rep.
      'usable': result.selectedSide != null,
      'lostStreak': result.lostStreak,
      'side': result.selectedSide,
      'sideSwitched': result.sideSwitched,
      'visL': result.leftVisibility,
      'visR': result.rightVisibility,
      'joints': {
        for (final joint in _squatJoints)
          joint: frame.landmarks[joint]?.likelihood,
      },
      'raw': result.rawAngle,
      'smooth': result.smoothedAngle,
      'phase': resultPhase.name,
      'reps': result.repCount,
      'shallow': result.shallowAttemptCount,
    });
  }

  /// One finalize attempt — accepted AND rejected. The rejected entry
  /// carries the measured median/spread so the evidence for the rejection
  /// survives the sample-buffer clearing (the whole point of this pass).
  void recordCalibration(CalibrationOutcome outcome) {
    switch (outcome) {
      case CalibrationAccepted(:final result, :final spread):
        _entries.add({
          'type': 'calibration',
          'result': 'accepted',
          'rest': result.restSignal,
          'spread': spread,
          'thresholds': {
            'startDescent': result.startDescent,
            'enterPeak': result.enterPeak,
            'enterRest': result.enterRest,
            'romTarget': result.romTarget,
          },
        });
      case CalibrationRejected(:final reason, :final median, :final spread):
        _entries.add({
          'type': 'calibration',
          'result': 'rejected',
          'reason': reason.name,
          'median': median,
          'spread': spread,
        });
    }
  }

  /// Serialises the whole session for pull-and-inspect (`adb logcat`).
  String exportJson({String movement = 'squat'}) {
    return jsonEncode({'movement': movement, 'entries': _entries});
  }

  void clear() {
    _entries.clear();
    _lastTimestampMs = null;
  }
}
