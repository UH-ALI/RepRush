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
    this.calibration,
    this.leftVisibility,
    this.rightVisibility,
    this.sideSwitched = false,
    this.lostStreak = 0,
    this.calibrationRejection,
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

  /// Frozen thresholds once calibration is accepted — rest angle plus the
  /// four gates. Null while calibrating. Debug-panel + diagnostics only;
  /// never serialized into Evidence.
  final CalibrationResult? calibration;

  /// Min-of-chain in-frame visibility per side (null = chain incomplete).
  /// Both sides are reported so a noisy-but-present chain shows up as low
  /// likelihood instead of hiding inside the selector.
  final double? leftVisibility;
  final double? rightVisibility;

  /// True on the frame the sticky selector switched sides.
  final bool sideSwitched;

  /// Sustained unusable frames — decays by one per usable frame, so a
  /// single spurious pass-through does not wipe the loss evidence.
  final int lostStreak;

  /// Why the last calibration attempt was rejected — drives the retry
  /// messaging while samples re-collect. Null after an accepted attempt.
  final CalibrationRejectionReason? calibrationRejection;
}

/// Two-phase pipeline: CALIBRATING (collect rest samples) then COUNTING.
class SquatPipeline {
  SquatPipeline(this.config) : _calibration = CalibrationCapture(config);

  final MovementConfig config;

  /// Sustained unusable frames before the red "Tracking lost" cue fires.
  static const int _lostAfterFrames = 3;

  /// Calibration window (~2 s at 15 fps); [CalibrationCapture.attemptFinalize]
  /// still enforces its own minimum.
  static const int _calibrationFrames = 30;

  final EmaFilter _ema = EmaFilter();
  final CalibrationCapture _calibration;
  final FeedbackDebouncer _debouncer = FeedbackDebouncer();

  RepMachine? _machine;
  bool _calibrating = true;
  int _lostStreak = 0;

  /// Sticky side selection state — hysteresis against per-frame flicker.
  String? _currentSide;

  /// Frozen thresholds once calibration is accepted.
  CalibrationResult? _calibrationResult;

  /// Why the last finalize attempt was rejected (null after acceptance).
  CalibrationRejectionReason? _lastRejection;

  /// The outcome of the most recent finalize attempt — the controller
  /// forwards it to the diagnostics trace (accepted AND rejected).
  CalibrationOutcome? lastCalibrationOutcome;

  int get repCount => _machine?.repCount ?? 0;
  int get shallowAttemptCount => _machine?.shallowAttemptCount ?? 0;
  bool get calibrating => _calibrating;
  int get calibrationSampleCount => _calibration.sampleCount;
  CalibrationResult? get calibration => _calibrationResult;

  /// Processes one frame. A null side selection clears everything drawable
  /// downstream — the controller maps `selectedSide == null` to a null
  /// overlay frame, so no stale skeleton survives tracking loss.
  PipelineFrame tick(LandmarkFrame frame) {
    final vis = sideVisibilities(
      frame.landmarks,
      imageWidth: frame.imageWidth,
      imageHeight: frame.imageHeight,
    );
    final selected = stickySelectSide(
      frame.landmarks,
      currentSide: _currentSide,
      imageWidth: frame.imageWidth,
      imageHeight: frame.imageHeight,
    );
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
        calibration: _calibrationResult,
        leftVisibility: vis.left,
        rightVisibility: vis.right,
        lostStreak: _lostStreak,
        calibrationRejection: _lastRejection,
      );
    }

    final sideSwitched = _currentSide != null && selected.side != _currentSide;
    _currentSide = selected.side;
    // Decay, not hard-reset: one spurious usable frame (stale landmarks
    // skimming the visibility floor) must not wipe the evidence of
    // sustained loss — the "Tracking lost" cue would fire inconsistently.
    if (_lostStreak > 0) _lostStreak -= 1;
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
        calibration: _calibrationResult,
        leftVisibility: vis.left,
        rightVisibility: vis.right,
        sideSwitched: sideSwitched,
        lostStreak: _lostStreak,
        calibrationRejection: _lastRejection,
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
      calibration: _calibrationResult,
      leftVisibility: vis.left,
      rightVisibility: vis.right,
      sideSwitched: sideSwitched,
      lostStreak: _lostStreak,
      calibrationRejection: _lastRejection,
    );
  }

  /// Freezes thresholds and enters the counting phase. Returns false when
  /// the attempt was rejected or not enough samples were collected — the
  /// caller stays in calibrating. A stability/plausibility rejection
  /// clears the sample window (a bad window never recovers by collecting
  /// more bad samples); a too-few-samples rejection keeps collecting.
  /// The full outcome is available via [lastCalibrationOutcome].
  bool finalizeCalibration({int minSamples = 10}) {
    final outcome = _calibration.attemptFinalize(minSamples: minSamples);
    lastCalibrationOutcome = outcome;
    switch (outcome) {
      case CalibrationAccepted(:final result):
        _calibrationResult = result;
        _machine = RepMachine(result, config);
        _calibrating = false;
        _lastRejection = null;
        return true;
      case CalibrationRejected(:final reason):
        _lastRejection = reason;
        if (reason != CalibrationRejectionReason.tooFewSamples) {
          _calibration.reset();
        }
        return false;
    }
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
    _currentSide = null;
    _calibrationResult = null;
    _lastRejection = null;
    lastCalibrationOutcome = null;
  }

  double _progress() {
    if (!_calibrating) return 1;
    final p = _calibration.sampleCount / _calibrationFrames;
    return p > 1 ? 1 : p;
  }
}
