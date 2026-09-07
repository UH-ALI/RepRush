/// Joint-chain angle math (roles.md A-5, signal conditioning).
///
/// Ownership: A. Purity rule: `dart:math` only.
library;

import 'dart:math' as math;

import 'package:reprush/features/capture/pipeline/types.dart';

/// The interior angle at the [vertex] formed by proximal → vertex →
/// distal, in degrees, normalised to 0–180. A fully extended chain reads
/// ~175° (standing knee, locked-out elbow); a deep squat drops to
/// ~70–80°.
double jointAngle(Lm proximal, Lm vertex, Lm distal) {
  final upper = math.atan2(proximal.y - vertex.y, proximal.x - vertex.x);
  final lower = math.atan2(distal.y - vertex.y, distal.x - vertex.x);
  var degrees = (lower - upper).abs() * 180 / math.pi;
  if (degrees > 180) degrees = 360 - degrees;
  return degrees;
}

/// Compatibility wrapper for the squat leg chain (hip–knee–ankle) —
/// identical math via [jointAngle].
double kneeAngle(Lm hip, Lm knee, Lm ankle) => jointAngle(hip, knee, ankle);
