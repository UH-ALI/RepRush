/// Movement configs — per-movement constants (roles.md A-7; threshold table
/// in api-contract.md §evidence). Offsets are RELATIVE to the calibrated
/// rest signal, never absolute angles (A-19).
///
/// Ownership: A. Purity rule: plain Dart only.
library;

/// Threshold offsets applied to the calibrated rest signal. For squat
/// (rest ≈ 175°): startDescent 163°, enterRest 150°, enterPeak 110°,
/// romTarget 80°.
class MovementConfig {
  const MovementConfig({
    required this.id,
    required this.startDescentOffset,
    required this.enterPeakOffset,
    required this.enterRestOffset,
    required this.romTargetOffset,
    required this.decreasing,
  });

  final String id;

  /// Gates REST → DESCENDING — fires early so amber "Go lower" shows while
  /// the athlete can still correct. Must sit between rest and enterRest.
  final double startDescentOffset;

  /// Gates DESCENDING → DEPTH_REACHED — the valid-depth gate.
  final double enterPeakOffset;

  /// Gates the return to REST (and counts the rep on the way up).
  final double enterRestOffset;

  /// Full ROM grade target (scoring milestone — carried, not consumed yet).
  final double romTargetOffset;

  /// True when the signal drops at peak (squat); false would mean it rises.
  final bool decreasing;
}

const squatConfig = MovementConfig(
  id: 'squat',
  startDescentOffset: -12.0,
  enterPeakOffset: -65.0,
  enterRestOffset: -25.0,
  romTargetOffset: -95.0,
  decreasing: true,
);
