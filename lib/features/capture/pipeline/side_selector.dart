/// Higher-visibility side selection (roles.md A-5).
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'package:reprush/features/capture/pipeline/types.dart';

/// The chosen body side: its hip-knee-ankle triplet, the weakest-link
/// visibility of the three, and which side it is.
typedef SelectedSide = ({
  Lm hip,
  Lm knee,
  Lm ankle,
  double minVisibility,
  String side,
});

/// Picks the side whose hip-knee-ankle chain is fully above [minVisibility]
/// and whose weakest landmark is the strongest. A usable frame needs only
/// ONE complete chain — an athlete turning mid-set switches sides instantly.
/// Returns `null` when neither side is usable: tracking lost for this frame.
///
/// Minimum, not mean: a single occluded joint corrupts the angle, so the
/// weakest link decides which side is safer to count from.
SelectedSide? selectBetterSide(
  Map<String, Lm> landmarks, {
  double minVisibility = 0.5,
}) {
  SelectedSide? best;
  for (final side in const ['left', 'right']) {
    final hip = landmarks['${side}Hip'];
    final knee = landmarks['${side}Knee'];
    final ankle = landmarks['${side}Ankle'];
    if (hip == null || knee == null || ankle == null) continue;
    final minVis = minOf3(hip.likelihood, knee.likelihood, ankle.likelihood);
    if (minVis < minVisibility) continue;
    if (best == null || minVis > best.minVisibility) {
      best = (
        hip: hip,
        knee: knee,
        ankle: ankle,
        minVisibility: minVis,
        side: side,
      );
    }
  }
  return best;
}

/// The smallest of three values — named so the purity rule stays obvious
/// without pulling in `dart:math` for one call site.
double minOf3(double a, double b, double c) {
  var min = a;
  if (b < min) min = b;
  if (c < min) min = c;
  return min;
}
