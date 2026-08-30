/// EMA smoothing for the angle signal (roles.md A-5 — smoothing is
/// mandatory upstream of the state machine, not polish).
///
/// Ownership: A. Purity rule: plain Dart only.
library;

/// Exponential moving average. `alpha` is the primary on-device tunable:
/// 0.35 at ~15 fps gives a ~2-frame effective window. One-euro is the
/// documented upgrade path — same `update(double)` interface, one-file swap.
class EmaFilter {
  EmaFilter({this.alpha = 0.35});

  final double alpha;

  double? _prev;

  /// The first sample passes through unfiltered.
  double update(double raw) {
    final prev = _prev;
    final smoothed = prev == null ? raw : alpha * raw + (1 - alpha) * prev;
    _prev = smoothed;
    return smoothed;
  }

  void reset() => _prev = null;
}
