/// Squat pipeline orchestrator — one entry point that composes side
/// selection, angle math, smoothing, calibration, the rep machine, and
/// feedback into a single per-frame result.
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'package:reprush/features/capture/pipeline/angle_math.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/ema_filter.dart';
import 'package:reprush/features/capture/pipeline/feedback.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';
import 'package:reprush/features/capture/pipeline/side_selector.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// Everything the UI needs from one processed frame.
class PipelineFrame {
  const PipelineFrame({
    required this.repCount,
    required this.shallowAttemptCount,
    required this.phase,
    required this.feedback,
    required this.rawAngle,
    required this.smoothedAngle,
    required this.justEmitted,
    required this.calibrating,
    required this.selectedSide,
    required this.calibrationProgress,
  });

  final int repCount;

  /// Local-only — never serialized.
  final int shallowAttemptCount;
  final RepPhase phase;
  final FeedbackSnapshot feedback;
  final double? rawAngle;
  final double? smoothedAngle;
  final RepEvent? justEmitted;
  final bool calibrating;

  /// `"left"` / `"right"` when a usable chain was selected, else null.
  final String? selectedSide;

  /// 0.0 → 1.0 while calibrating, 1.0 once counting.
  final double calibrationProgress;
}

/// Two-phase pipeline: CALIBRATING (collect rest samples) then COUNTING.
class SquatPipeline {
  SquatPipeline(this.config) : _calibration = CalibrationCapture(config);

  final MovementConfig config;

  /// Sustained unusable frames before the red "Tracking lost" cue fires.
  static const int _lostAfterFrames = 3;

  /// Calibration window (~2 s at 15 fps); [CalibrationCapture.finalize]
  /// still enforces its own minimum.
  static const int _calibrationFrames = 30;

  final EmaFilter _ema = EmaFilter();
  final CalibrationCapture _calibration;
  final FeedbackDebouncer _debouncer = FeedbackDebouncer();

  RepMachine? _machine;
  bool _calibrating = true;
  int _lostStreak = 0;

  int get repCount => _machine?.repCount ?? 0;
  int get shallowAttemptCount => _machine?.shallowAttemptCount ?? 0;
  bool get calibrating => _calibrating;
  int get calibrationSampleCount => _calibration.sampleCount;

  /// Processes one frame. A null side selection clears everything drawable
  /// downstream — the controller maps `selectedSide == null` to a null
  /// overlay frame, so no stale skeleton survives tracking loss.
  PipelineFrame tick(LandmarkFrame frame) {
    final selected = selectBetterSide(frame.landmarks);
    if (selected == null) {
      _lostStreak += 1;
      final machine = _machine;
      final result = !_calibrating && machine != null
          ? machine.tickLost()
          : null;
      final lost = _lostStreak >= _lostAfterFrames;
      final feedback = lost
          ? const FeedbackSnapshot(
              level: FeedbackLevel.red,
              cue: 'Tracking lost',
            )
          : _debouncer.update(
              _calibrating
                  ? const FeedbackSnapshot(
                      level: FeedbackLevel.green,
                      cue: 'Hold still — calibrating',
                    )
                  : evaluateFeedback(
                      phase: result?.phase ?? RepPhase.rest,
                      trackingLost: false,
                      machineResult: result,
                    ),
            );
      return PipelineFrame(
        repCount: result?.repCount ?? repCount,
        shallowAttemptCount: result?.shallowAttemptCount ?? shallowAttemptCount,
        phase: result?.phase ?? RepPhase.rest,
        feedback: feedback,
        rawAngle: null,
        smoothedAngle: null,
        justEmitted: null,
        calibrating: _calibrating,
        selectedSide: null,
        calibrationProgress: _progress(),
      );
    }

    _lostStreak = 0;
    final raw = kneeAngle(selected.hip, selected.knee, selected.ankle);
    final smoothed = _ema.update(raw);

    if (_calibrating) {
      _calibration.addSample(kneeAngle: smoothed);
      return PipelineFrame(
        repCount: 0,
        shallowAttemptCount: 0,
        phase: RepPhase.rest,
        feedback: FeedbackSnapshot(
          level: FeedbackLevel.green,
          cue: 'Hold still — calibrating',
          activeSide: selected.side,
        ),
        rawAngle: raw,
        smoothedAngle: smoothed,
        justEmitted: null,
        calibrating: true,
        selectedSide: selected.side,
        calibrationProgress: _progress(),
      );
    }

    final machine = _machine!;
    final result = machine.tick(
      smoothed,
      selected.minVisibility,
      frame.timestampMs,
    );
    final feedback = _debouncer.update(
      evaluateFeedback(
        phase: result.phase,
        trackingLost: false,
        machineResult: result,
        activeSide: selected.side,
      ),
    );
    return PipelineFrame(
      repCount: result.repCount,
      shallowAttemptCount: result.shallowAttemptCount,
      phase: result.phase,
      feedback: feedback,
      rawAngle: raw,
      smoothedAngle: smoothed,
      justEmitted: result.emitted,
      calibrating: false,
      selectedSide: selected.side,
      calibrationProgress: 1,
    );
  }

  /// Freezes thresholds and enters the counting phase. Returns false when
  /// not enough samples were collected — the caller stays in calibrating
  /// and keeps collecting.
  bool finalizeCalibration({int minSamples = 10}) {
    final result = _calibration.finalize(minSamples: minSamples);
    if (result == null) return false;
    _machine = RepMachine(result, config);
    _calibrating = false;
    return true;
  }

  /// Whether enough samples have accumulated for [finalizeCalibration] to
  /// have a real chance — the controller auto-finalizes on this edge.
  bool get hasEnoughCalibrationSamples =>
      _calibration.sampleCount >= _calibrationFrames;

  void reset() {
    _calibrating = true;
    _machine = null;
    _ema.reset();
    _calibration.reset();
    _debouncer.reset();
    _lostStreak = 0;
  }

  double _progress() {
    if (!_calibrating) return 1;
    final p = _calibration.sampleCount / _calibrationFrames;
    return p > 1 ? 1 : p;
  }
}
