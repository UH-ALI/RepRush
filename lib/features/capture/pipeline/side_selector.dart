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

/// Per-frame visibility hysteresis margin: the current side is kept
/// unless the other usable side beats it by THIS much weakest-link
/// visibility. Kills per-frame flicker between near-tied sides without
/// delaying a genuine turn-around (the losing side drops below the
/// usability floor and the switch is instant anyway).
const double sideSwitchMargin = 0.10;

/// Min-of-chain visibility per side regardless of usability — the debug
/// panel shows both so a noisy-but-present landmark chain is visible as
/// low likelihood, not just as "selected/unselected". Null when that
/// side's chain is incomplete or outside the image bounds.
({double? left, double? right}) sideVisibilities(
  Map<String, Lm> landmarks, {
  double? imageWidth,
  double? imageHeight,
}) {
  double? chainMin(String side) {
    final hip = landmarks['${side}Hip'];
    final knee = landmarks['${side}Knee'];
    final ankle = landmarks['${side}Ankle'];
    if (hip == null || knee == null || ankle == null) return null;
    if (!inImageBounds(hip, imageWidth: imageWidth, imageHeight: imageHeight) ||
        !inImageBounds(
          knee,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ) ||
        !inImageBounds(
          ankle,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        )) {
      return null;
    }
    return minOf3(hip.likelihood, knee.likelihood, ankle.likelihood);
  }

  return (left: chainMin('left'), right: chainMin('right'));
}

/// Whether a landmark lies inside the rotated image bounds. ML Kit can
/// return stale, extrapolated landmarks when the athlete exits frame —
/// their likelihood hovers near the usability floor and flickers the
/// selector, so position is checked regardless of reported likelihood.
/// Frames without dimensions (synthetic fixtures) skip the check.
bool inImageBounds(Lm lm, {double? imageWidth, double? imageHeight}) {
  final w = imageWidth;
  final h = imageHeight;
  if (w == null || h == null) return true;
  return lm.x >= 0 && lm.x <= w && lm.y >= 0 && lm.y <= h;
}

/// Picks the side whose hip-knee-ankle chain is fully above [minVisibility]
/// and inside the image bounds, and whose weakest landmark is the
/// strongest. A usable frame needs only ONE complete chain — an athlete
/// turning mid-set switches sides instantly. Returns `null` when neither
/// side is usable: tracking lost for this frame.
///
/// Minimum, not mean: a single occluded joint corrupts the angle, so the
/// weakest link decides which side is safer to count from.
SelectedSide? selectBetterSide(
  Map<String, Lm> landmarks, {
  double minVisibility = 0.5,
  double? imageWidth,
  double? imageHeight,
}) {
  SelectedSide? best;
  for (final side in const ['left', 'right']) {
    final hip = landmarks['${side}Hip'];
    final knee = landmarks['${side}Knee'];
    final ankle = landmarks['${side}Ankle'];
    if (hip == null || knee == null || ankle == null) continue;
    // Out-of-bounds landmarks are unusable no matter their likelihood —
    // extrapolated positions cannot yield a trustworthy knee angle.
    if (!inImageBounds(hip, imageWidth: imageWidth, imageHeight: imageHeight) ||
        !inImageBounds(
          knee,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ) ||
        !inImageBounds(
          ankle,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        )) {
      continue;
    }
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

/// Stateful side selection on top of [selectBetterSide] — the selector
/// itself stays a pure per-frame function; the pipeline holds
/// [currentSide] and applies the hysteresis.
///
/// Rules:
/// * no current side (first usable frame, or after a loss) → strongest
///   usable side, exactly like [selectBetterSide];
/// * current side still usable → kept unless the other usable side beats
///   it by more than [switchMargin];
/// * current side no longer usable → instant switch to the usable side
///   (genuine turn-around must never wait on a margin).
SelectedSide? stickySelectSide(
  Map<String, Lm> landmarks, {
  String? currentSide,
  double minVisibility = 0.5,
  double switchMargin = sideSwitchMargin,
  double? imageWidth,
  double? imageHeight,
}) {
  final best = selectBetterSide(
    landmarks,
    minVisibility: minVisibility,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
  if (best == null || currentSide == null || best.side == currentSide) {
    return best;
  }
  // best is the OTHER side. Find the current side's chain, if still usable.
  final side = currentSide;
  final hip = landmarks['${side}Hip'];
  final knee = landmarks['${side}Knee'];
  final ankle = landmarks['${side}Ankle'];
  if (hip == null || knee == null || ankle == null) return best;
  if (!inImageBounds(hip, imageWidth: imageWidth, imageHeight: imageHeight) ||
      !inImageBounds(knee, imageWidth: imageWidth, imageHeight: imageHeight) ||
      !inImageBounds(ankle, imageWidth: imageWidth, imageHeight: imageHeight)) {
    return best;
  }
  final currentVis = minOf3(hip.likelihood, knee.likelihood, ankle.likelihood);
  if (currentVis < minVisibility) return best;
  return best.minVisibility > currentVis + switchMargin
      ? best
      : (
          hip: hip,
          knee: knee,
          ankle: ankle,
          minVisibility: currentVis,
          side: side,
        );
}
