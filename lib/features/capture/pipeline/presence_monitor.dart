/// Presence + identity-consistency monitors — the integrity side of a set.
///
/// [PresenceMonitor]: if the athlete's body is lost for longer than a short
/// flicker grace, the set ENDS (it is not "idle"): otherwise someone could
/// leave and a different person continue the same set.
///
/// [BodyScaleMonitor]: while the athlete is back in the calibration pose,
/// the live torso length must stay close to the calibrated one. A sustained
/// difference means a different body (or a moved camera) — FLAG ONLY for
/// now; nothing ends the set on it until the flag is validated on real data.
///
/// Ownership: A. Purity rule: plain Dart only (time comes from frame
/// timestamps so replay is deterministic).
library;

class PresenceConfig {
  const PresenceConfig({this.warnAfterMs = 600, this.graceMs = 2000});

  /// Shorter gaps are treated as detector flicker (ML Kit drops the pose
  /// for a few frames in motion blur / bad light) and show nothing.
  final int warnAfterMs;

  /// Continuous absence that ends the set. A real walk-out lasts longer;
  /// 2 s is ~30 frames at 15 fps, far beyond normal dropouts.
  final int graceMs;
}

enum PresenceStage { present, absent, left }

class PresenceStatus {
  const PresenceStatus(this.stage, {this.remainingMs = 0});

  static const PresenceStatus present = PresenceStatus(PresenceStage.present);

  final PresenceStage stage;

  /// While [stage] is [PresenceStage.absent]: ms until the set ends.
  final int remainingMs;

  bool get isAbsent => stage == PresenceStage.absent;
  bool get hasLeft => stage == PresenceStage.left;
}

class PresenceMonitor {
  PresenceMonitor([this.config = const PresenceConfig()]);

  final PresenceConfig config;

  int? _absentSinceMs;
  bool _left = false;

  /// Call on EVERY frame. [bodyVisible] is false when the pipeline could
  /// not select a usable joint chain. With no reps there is nothing to
  /// protect or save, so the monitor stays [PresenceStatus.present].
  PresenceStatus tick({
    required bool bodyVisible,
    required int repCount,
    required int timestampMs,
  }) {
    if (_left) return const PresenceStatus(PresenceStage.left);
    if (bodyVisible || repCount == 0) {
      _absentSinceMs = null;
      return PresenceStatus.present;
    }
    final since = _absentSinceMs ??= timestampMs;
    final absentMs = timestampMs - since;
    if (absentMs < config.warnAfterMs) return PresenceStatus.present;
    if (absentMs >= config.graceMs) {
      _left = true;
      return const PresenceStatus(PresenceStage.left);
    }
    return PresenceStatus(
      PresenceStage.absent,
      remainingMs: config.graceMs - absentMs,
    );
  }

  void reset() {
    _absentSinceMs = null;
    _left = false;
  }
}

class BodyScaleConfig {
  const BodyScaleConfig({this.window = 10, this.tolerance = 0.20});

  /// Rest-pose samples in the sliding window; the median is judged, so a
  /// few noisy frames cannot trigger the flag.
  final int window;

  /// Allowed fractional deviation of live vs calibrated torso length.
  /// Starting value, to be tuned from the logged ratios on real sets —
  /// same-size people will not be caught by any size check.
  final double tolerance;
}

class BodyScaleMonitor {
  BodyScaleMonitor([this.config = const BodyScaleConfig()]);

  final BodyScaleConfig config;

  final List<double> _ratios = [];
  double? _medianRatio;
  bool _mismatch = false;

  /// Median live/calibrated torso ratio over the window, once it is full.
  double? get medianRatio => _medianRatio;

  /// Sticky until [reset]: once a different body is suspected, the set is
  /// marked for the rest of its life.
  bool get mismatch => _mismatch;

  /// Only rest-phase frames are compared: there the athlete is in the same
  /// upright pose as at calibration, so projected torso length is
  /// comparable. Mid-rep it legitimately changes (a squat leans the torso).
  void tick({
    required double? torsoPx,
    required double? calibratedTorsoPx,
    required bool atRest,
  }) {
    if (!atRest || torsoPx == null) return;
    if (calibratedTorsoPx == null || calibratedTorsoPx <= 0) return;
    _ratios.add(torsoPx / calibratedTorsoPx);
    if (_ratios.length > config.window) _ratios.removeAt(0);
    if (_ratios.length < config.window) return;
    final sorted = [..._ratios]..sort();
    final mid = sorted.length ~/ 2;
    _medianRatio = sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
    if ((_medianRatio! - 1).abs() > config.tolerance) _mismatch = true;
  }

  void reset() {
    _ratios.clear();
    _medianRatio = null;
    _mismatch = false;
  }
}
