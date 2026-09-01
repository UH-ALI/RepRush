/// Feedback logic (requirements.md B5/B6) — substate-driven coaching cues.
/// Amber fires DURING descent while the athlete can still correct; red fires
/// immediately on a shallow return instead of silent failure.
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// One frame of coaching feedback for the HUD and the overlay colours.
class FeedbackSnapshot {
  const FeedbackSnapshot({
    required this.level,
    required this.cue,
    this.repJustCounted = false,
    this.shallowReturn = false,
    this.activeSide,
  });

  final FeedbackLevel level;
  final String cue;
  final bool repJustCounted;
  final bool shallowReturn;

  /// `"left"` or `"right"` — the side the machine is counting from.
  final String? activeSide;
}

/// Maps machine substates to a feedback level + cue. Pure and immediate —
/// debounce timing is [FeedbackDebouncer]'s job.
FeedbackSnapshot evaluateFeedback({
  required RepPhase phase,
  required bool trackingLost,
  required RepMachineResult? machineResult,
  String? activeSide,
}) {
  if (trackingLost) {
    return const FeedbackSnapshot(
      level: FeedbackLevel.red,
      cue: 'Tracking lost',
    );
  }
  final result = machineResult;
  if (result != null) {
    if (result.shallowReturn) {
      return FeedbackSnapshot(
        level: FeedbackLevel.red,
        cue: 'Not counted — go lower next rep',
        shallowReturn: true,
        activeSide: activeSide,
      );
    }
    if (result.emitted != null) {
      return FeedbackSnapshot(
        level: FeedbackLevel.green,
        cue: 'Rep counted',
        repJustCounted: true,
        activeSide: activeSide,
      );
    }
  }
  return switch (phase) {
    RepPhase.rest => FeedbackSnapshot(
      level: FeedbackLevel.green,
      cue: 'Ready',
      activeSide: activeSide,
    ),
    RepPhase.descending => FeedbackSnapshot(
      level: FeedbackLevel.amber,
      cue: 'Go lower',
      activeSide: activeSide,
    ),
    RepPhase.depthReached => FeedbackSnapshot(
      level: FeedbackLevel.green,
      cue: 'Good depth',
      activeSide: activeSide,
    ),
    RepPhase.ascending => FeedbackSnapshot(
      level: FeedbackLevel.green,
      cue: 'Stand tall',
      activeSide: activeSide,
    ),
  };
}

/// Retry messaging for rejected calibration attempts — shown while the
/// sample window re-collects. Pure so it stays testable alongside the
/// rest of the feedback logic.
String calibrationRejectionMessage(CalibrationRejectionReason reason) {
  return switch (reason) {
    CalibrationRejectionReason.tooFewSamples =>
      'Not enough steady frames yet — hold your position',
    CalibrationRejectionReason.unstableRest =>
      'Too much movement — stand still while we retry',
    CalibrationRejectionReason.implausibleRest =>
      'Stand side-on, straighten your legs, keep full body in frame — retrying',
  };
}

/// Holds flicker-prone transitions for [debounceFrames] consecutive frames
/// (~200 ms at 15 fps). Two cues bypass debounce entirely — they must feel
/// instant: the shallow-return red and the rep-counted green. Both hold for
/// a short window afterwards so they are not overwritten on the next frame.
class FeedbackDebouncer {
  FeedbackDebouncer({
    this.debounceFrames = 3,
    this.shallowHoldFrames = 15,
    this.repHoldFrames = 8,
  });

  final int debounceFrames;
  final int shallowHoldFrames;
  final int repHoldFrames;

  FeedbackSnapshot? _current;
  FeedbackSnapshot? _pending;
  int _pendingStreak = 0;
  int _holdRemaining = 0;
  bool _holding = false;

  FeedbackSnapshot update(FeedbackSnapshot proposed) {
    // High-priority cues fire immediately and hold their slot.
    if (proposed.shallowReturn) {
      _holdRemaining = shallowHoldFrames;
      _holding = true;
      _pending = null;
      _pendingStreak = 0;
      return _current = proposed;
    }
    if (proposed.repJustCounted) {
      _holdRemaining = repHoldFrames;
      _holding = true;
      _pending = null;
      _pendingStreak = 0;
      return _current = proposed;
    }
    if (_holdRemaining > 0) {
      _holdRemaining -= 1;
      return _current!;
    }
    if (_holding) {
      // Hold window is over — the proposal on this frame is authoritative,
      // adopt it immediately instead of re-debouncing it.
      _holding = false;
      _pending = null;
      _pendingStreak = 0;
      return _current = proposed;
    }

    final current = _current;
    if (current == null) {
      // First-ever update establishes the baseline without a wait.
      return _current = proposed;
    }
    if (current.cue == proposed.cue) {
      _pending = null;
      _pendingStreak = 0;
      return current;
    }
    final pending = _pending;
    if (pending != null && pending.cue == proposed.cue) {
      _pendingStreak += 1;
    } else {
      _pending = proposed;
      _pendingStreak = 1;
    }
    if (_pendingStreak >= debounceFrames) {
      _pending = null;
      _pendingStreak = 0;
      return _current = proposed;
    }
    return current;
  }

  void reset() {
    _current = null;
    _pending = null;
    _pendingStreak = 0;
    _holdRemaining = 0;
    _holding = false;
  }
}
