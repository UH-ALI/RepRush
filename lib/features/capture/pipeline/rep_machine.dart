/// Rep state machine (roles.md A-6) — four explicit substates model the
/// full squat cycle so feedback fires WHILE the athlete can still correct.
///
/// Ownership: A. Purity rule: plain Dart only. Zero allocations during a
/// rep — a [RepEvent] is allocated only on valid emission.
library;

import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';

/// The four substates of one movement cycle.
enum RepPhase { rest, descending, depthReached, ascending }

/// One completed valid rep — the fields Evidence will later serialize
/// (api-contract.md §evidence). Shallow attempts NEVER become RepEvents.
class RepEvent {
  const RepEvent({
    required this.index,
    required this.tStartMs,
    required this.tEndMs,
    required this.restExtreme,
    required this.peakExtreme,
    required this.confMean,
    required this.confMin,
  });

  final int index;
  final int tStartMs;
  final int tEndMs;

  /// Rest angle at descent start (tempo/grade inputs, carried un-scored).
  final double restExtreme;

  /// Deepest angle reached this rep.
  final double peakExtreme;

  /// Mean in-frame visibility over the rep.
  final double confMean;

  /// Min in-frame visibility over the rep.
  final double confMin;
}

/// The per-tick machine output.
class RepMachineResult {
  const RepMachineResult({
    required this.phase,
    required this.repCount,
    required this.shallowAttemptCount,
    this.emitted,
    this.shallowReturn = false,
  });

  final RepPhase phase;
  final int repCount;

  /// Local-only — never serialized into reps, Evidence, score, or XP.
  final int shallowAttemptCount;

  /// Non-null exactly on the frame a valid rep completes.
  final RepEvent? emitted;

  /// True for one frame on DESCENDING → REST without depth.
  final bool shallowReturn;
}

/// Two-threshold hysteresis counting machine for decreasing signals
/// (squat: angle drops at depth). Direction-aware via [config].
class RepMachine {
  RepMachine(this.cal, this.config) : assert(config.decreasing);

  final CalibrationResult cal;
  final MovementConfig config;

  /// Consecutive rising frames needed to enter ASCENDING — single-frame
  /// noise at the bottom must not flip the machine.
  static const int _risingConfirmFrames = 2;

  /// Escape hatch out of DEPTH_REACHED even before the streak confirms.
  static const double _risingMargin = 3.0;

  /// After any rep-end event (valid emission or shallow return) the EMA
  /// signal dips below [CalibrationResult.startDescent] for a few frames
  /// while it catches up with the athlete, who is already back on top.
  /// The machine disarms across that dip and re-arms once the smoothed
  /// signal recovers into the rest zone — without this gate the dips
  /// become phantom shallow attempts (double counting between reps).

  /// Sustained tracking loss mid-rep discards the rep (failure, not form).
  static const int _lostAfterFrames = 15;

  int _repCount = 0;
  int _shallowAttempts = 0;
  RepPhase _phase = RepPhase.rest;
  int _tStartMs = 0;
  double _restExtreme = 0;
  double _peakExtreme = 0;
  double _confSum = 0;
  double _confMin = 1;
  int _confCount = 0;
  double? _prevAngle;
  int _risingStreak = 0;
  int _missStreak = 0;
  bool _armed = true;

  int get repCount => _repCount;
  int get shallowAttemptCount => _shallowAttempts;
  RepPhase get phase => _phase;

  /// One usable frame: advance the machine with the smoothed angle.
  RepMachineResult tick(
    double smoothedAngle,
    double meanVisibility,
    int timestampMs,
  ) {
    _missStreak = 0;
    RepEvent? emitted;
    var shallowReturn = false;

    switch (_phase) {
      case RepPhase.rest:
        _restExtreme = smoothedAngle;
        if (!_armed) {
          // Absorb the EMA-lag dip after a rep-end event: the signal falls
          // through startDescent while the athlete stands, then recovers.
          // Only once it is back in the rest zone is the next descent real.
          if (smoothedAngle >= cal.enterRest) _armed = true;
        } else if (smoothedAngle <= cal.startDescent) {
          _phase = RepPhase.descending;
          _tStartMs = timestampMs;
          _peakExtreme = smoothedAngle;
          _confSum = 0;
          _confMin = 1;
          _confCount = 0;
          _risingStreak = 0;
        }
      case RepPhase.descending:
        _accumulate(meanVisibility);
        if (smoothedAngle < _peakExtreme) _peakExtreme = smoothedAngle;
        if (smoothedAngle <= cal.enterPeak) {
          _phase = RepPhase.depthReached;
          _risingStreak = 0;
        } else if (smoothedAngle >= cal.enterRest) {
          if (_peakExtreme < cal.enterRest) {
            // Shallow attempt — local only, never serialized. Requires the
            // signal to have genuinely left the rest zone first; otherwise
            // the slow EMA entry into the band would flag every descent.
            _shallowAttempts += 1;
            shallowReturn = true;
            _armed = false;
          }
          _phase = RepPhase.rest;
        }
      case RepPhase.depthReached:
        _accumulate(meanVisibility);
        if (smoothedAngle < _peakExtreme) _peakExtreme = smoothedAngle;
        final prev = _prevAngle;
        if (prev != null && smoothedAngle > prev) {
          _risingStreak += 1;
        } else {
          _risingStreak = 0;
        }
        if (_risingStreak >= _risingConfirmFrames ||
            smoothedAngle > _peakExtreme + _risingMargin) {
          _phase = RepPhase.ascending;
        }
      case RepPhase.ascending:
        _accumulate(meanVisibility);
        if (smoothedAngle >= cal.enterRest) {
          _repCount += 1;
          emitted = RepEvent(
            index: _repCount,
            tStartMs: _tStartMs,
            tEndMs: timestampMs,
            restExtreme: _restExtreme,
            peakExtreme: _peakExtreme,
            confMean: _confCount == 0 ? meanVisibility : _confSum / _confCount,
            confMin: _confCount == 0 ? meanVisibility : _confMin,
          );
          _phase = RepPhase.rest;
          _restExtreme = smoothedAngle;
          _armed = false;
        }
    }

    _prevAngle = smoothedAngle;
    return RepMachineResult(
      phase: _phase,
      repCount: _repCount,
      shallowAttemptCount: _shallowAttempts,
      emitted: emitted,
      shallowReturn: shallowReturn,
    );
  }

  /// One unusable frame (side selector returned null). Sustained loss
  /// mid-rep resets to REST — no emission, no shallow count.
  RepMachineResult tickLost() {
    _missStreak += 1;
    if (_phase != RepPhase.rest && _missStreak >= _lostAfterFrames) {
      _resetRep();
    }
    return RepMachineResult(
      phase: _phase,
      repCount: _repCount,
      shallowAttemptCount: _shallowAttempts,
    );
  }

  void _accumulate(double meanVisibility) {
    _confSum += meanVisibility;
    if (meanVisibility < _confMin) _confMin = meanVisibility;
    _confCount += 1;
  }

  void _resetRep() {
    _phase = RepPhase.rest;
    _risingStreak = 0;
    _prevAngle = null;
    _armed = true;
  }

  void reset() {
    _repCount = 0;
    _shallowAttempts = 0;
    _missStreak = 0;
    _resetRep();
  }
}
