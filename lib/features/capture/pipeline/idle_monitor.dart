/// Idle monitor — detects that the athlete has stopped mid-set (a rest, a
/// phone call, walking away) so the set can be saved instead of the pipeline
/// counting the next movement as a continuation.
///
/// Flow: after the athlete's last activity, wait [IdleConfig] threshold
/// (adaptive to their own rep tempo), then raise a WARNING with a visible
/// countdown ("saving in 3…2…1"), then EXPIRE. Any new activity during the
/// warning cancels it — a false alarm costs nothing.
///
/// "Activity" is defined by the rep machine, not by raw angle noise: the
/// machine only leaves REST when the signal crosses `startDescent`, which is
/// calibrated per athlete, so fidgeting while resting is not activity.
///
/// Ownership: A. Purity rule: plain Dart only (no Flutter, no clocks — time
/// comes from frame timestamps so the monitor replays deterministically).
library;

import 'package:reprush/features/capture/pipeline/rep_machine.dart';

/// Tunables, each derived from observable tempo rather than guessed per
/// exercise. See [SetIdleMonitor.thresholdMs] for the formula.
class IdleConfig {
  const IdleConfig({
    this.tempoMultiplier = 3.0,
    this.minThresholdMs = 5000,
    this.maxThresholdMs = 15000,
    this.defaultThresholdMs = 8000,
    this.warningMs = 3000,
    this.tempoWindow = 5,
  });

  /// Idle only starts after this many median inter-rep intervals of
  /// stillness. A pause inside a continuous set (re-gripping, breathing)
  /// is rarely longer than ~2 intervals; 3 leaves margin so a deliberate
  /// slow rhythm is never mistaken for a rest.
  final double tempoMultiplier;

  /// Floor: even for very fast reps, never warn sooner than this. Stops
  /// a brief reposition from triggering the countdown.
  final int minThresholdMs;

  /// Ceiling: even for very slow reps, never wait longer than this before
  /// warning, so the set is saved in a predictable time.
  final int maxThresholdMs;

  /// Used until two reps exist (no tempo can be measured yet).
  final int defaultThresholdMs;

  /// Length of the visible countdown before the set is saved.
  final int warningMs;

  /// How many recent inter-rep intervals feed the median tempo.
  final int tempoWindow;
}

enum IdleStage { active, warning, expired }

/// Per-frame idle state for the UI/controller.
class IdleStatus {
  const IdleStatus(this.stage, {this.secondsLeft = 0});

  static const IdleStatus active = IdleStatus(IdleStage.active);

  final IdleStage stage;

  /// While [stage] is [IdleStage.warning]: whole seconds remaining,
  /// 3 → 2 → 1 (ceil), never 0. Zero otherwise.
  final int secondsLeft;

  bool get isWarning => stage == IdleStage.warning;
  bool get isExpired => stage == IdleStage.expired;
}

class SetIdleMonitor {
  SetIdleMonitor([this.config = const IdleConfig()]);

  final IdleConfig config;

  /// Timestamps (ms) of the most recent rep completions — tempo source.
  final List<int> _repEndsMs = [];
  int _lastRepCount = 0;
  int? _lastActivityMs;
  bool _expired = false;

  /// Current idle threshold in ms: three median inter-rep intervals,
  /// clamped to [IdleConfig.minThresholdMs, IdleConfig.maxThresholdMs];
  /// [IdleConfig.defaultThresholdMs] before two reps exist.
  int get thresholdMs {
    if (_repEndsMs.length < 2) return config.defaultThresholdMs;
    final intervals = <int>[
      for (var i = 1; i < _repEndsMs.length; i++)
        _repEndsMs[i] - _repEndsMs[i - 1],
    ]..sort();
    final mid = intervals.length ~/ 2;
    final median = intervals.length.isOdd
        ? intervals[mid].toDouble()
        : (intervals[mid - 1] + intervals[mid]) / 2;
    final raw = (median * config.tempoMultiplier).round();
    return raw.clamp(config.minThresholdMs, config.maxThresholdMs);
  }

  /// One pipeline tick. [phase] and [repCount] come from the rep machine;
  /// [timestampMs] is the session-clock frame time. Call on EVERY frame,
  /// including tracking-lost ones — an athlete who left the frame is idle.
  ///
  /// Before the first rep there is nothing to save, so the monitor stays
  /// [IdleStatus.active]. Once expired it latches (the caller saves the
  /// set exactly once) until [reset].
  IdleStatus tick({
    required RepPhase phase,
    required int repCount,
    required int timestampMs,
  }) {
    if (repCount > _lastRepCount) {
      _repEndsMs.add(timestampMs);
      if (_repEndsMs.length > config.tempoWindow + 1) _repEndsMs.removeAt(0);
      _lastActivityMs = timestampMs;
    }
    _lastRepCount = repCount;
    if (phase != RepPhase.rest) _lastActivityMs = timestampMs;

    if (_expired) return const IdleStatus(IdleStage.expired);
    final last = _lastActivityMs;
    if (repCount == 0 || last == null) return IdleStatus.active;

    final idleMs = timestampMs - last;
    final threshold = thresholdMs;
    if (idleMs < threshold) return IdleStatus.active;

    final intoWarning = idleMs - threshold;
    if (intoWarning >= config.warningMs) {
      _expired = true;
      return const IdleStatus(IdleStage.expired);
    }
    final remainingMs = config.warningMs - intoWarning;
    return IdleStatus(
      IdleStage.warning,
      secondsLeft: (remainingMs / 1000).ceil(),
    );
  }

  void reset() {
    _repEndsMs.clear();
    _lastRepCount = 0;
    _lastActivityMs = null;
    _expired = false;
  }
}
