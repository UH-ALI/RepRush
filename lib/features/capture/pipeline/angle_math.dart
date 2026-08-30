/// Hip-knee-ankle angle math (roles.md A-5, signal conditioning).
///
/// Ownership: A. Purity rule: `dart:math` only.
library;

import 'dart:math' as math;

import 'package:reprush/features/capture/pipeline/types.dart';

/// The interior angle at the [knee] vertex formed by hip → knee → ankle,
/// in degrees, normalised to 0–180. A fully extended leg reads ~175°;
/// a deep squat drops to ~70–80°.
double kneeAngle(Lm hip, Lm knee, Lm ankle) {
  final thigh = math.atan2(hip.y - knee.y, hip.x - knee.x);
  final shin = math.atan2(ankle.y - knee.y, ankle.x - knee.x);
  var degrees = (shin - thigh).abs() * 180 / math.pi;
  if (degrees > 180) degrees = 360 - degrees;
  return degrees;
}
