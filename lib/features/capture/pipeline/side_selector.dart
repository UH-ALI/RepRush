/// Higher-visibility side selection (roles.md A-5) over a 3-point joint
/// chain — which body side's chain (leg: hip–knee–ankle, arm: shoulder–
/// elbow–wrist) is most trustworthy this frame.
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// The chosen body side: its proximal → vertex → distal landmark triplet,
/// the weakest-link visibility of the three, and which side it is.
typedef SelectedSide = ({
  Lm proximal,
  Lm vertex,
  Lm distal,
  double minVisibility,
  String side,
});

/// Per-frame visibility hysteresis margin: the current side is kept
/// unless the other usable side beats it by THIS much weakest-link
/// visibility. Kills per-frame flicker between near-tied sides without
/// delaying a genuine turn-around (the losing side drops below the
/// usability floor and the switch is instant anyway).
const double sideSwitchMargin = 0.10;

/// Per-side chain resolution — null when any of the three landmarks is
/// missing.
({Lm proximal, Lm vertex, Lm distal})? chainFor(
  Map<String, Lm> landmarks,
  String side,
  JointChain chain,
) {
  final proximal = landmarks['$side${chain.proximal}'];
  final vertex = landmarks['$side${chain.vertex}'];
  final distal = landmarks['$side${chain.distal}'];
  if (proximal == null || vertex == null || distal == null) return null;
  return (proximal: proximal, vertex: vertex, distal: distal);
}

/// Min-of-chain visibility per side regardless of usability — the debug
/// panel shows both so a noisy-but-present landmark chain is visible as
/// low likelihood, not just as "selected/unselected". Null when that
/// side's chain is incomplete or outside the image bounds.
({double? left, double? right}) sideVisibilities(
  Map<String, Lm> landmarks, {
  JointChain chain = JointChain.leg,
  double? imageWidth,
  double? imageHeight,
}) {
  double? chainMin(String side) {
    final resolved = chainFor(landmarks, side, chain);
    if (resolved == null) return null;
    if (!inImageBounds(
          resolved.proximal,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ) ||
        !inImageBounds(
          resolved.vertex,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ) ||
        !inImageBounds(
          resolved.distal,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        )) {
      return null;
    }
    return minOf3(
      resolved.proximal.likelihood,
      resolved.vertex.likelihood,
      resolved.distal.likelihood,
    );
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

/// Picks the side whose chain is fully above [minVisibility] and inside
/// the image bounds, and whose weakest landmark is the strongest. A
/// usable frame needs only ONE complete chain — an athlete turning
/// mid-set switches sides instantly. Returns `null` when neither side is
/// usable: tracking lost for this frame.
///
/// Minimum, not mean: a single occluded joint corrupts the angle, so the
/// weakest link decides which side is safer to count from.
SelectedSide? selectBetterSide(
  Map<String, Lm> landmarks, {
  double minVisibility = 0.5,
  JointChain chain = JointChain.leg,
  double? imageWidth,
  double? imageHeight,
}) {
  SelectedSide? best;
  for (final side in const ['left', 'right']) {
    final resolved = chainFor(landmarks, side, chain);
    if (resolved == null) continue;
    // Out-of-bounds landmarks are unusable no matter their likelihood —
    // extrapolated positions cannot yield a trustworthy joint angle.
    if (!inImageBounds(
          resolved.proximal,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ) ||
        !inImageBounds(
          resolved.vertex,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        ) ||
        !inImageBounds(
          resolved.distal,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        )) {
      continue;
    }
    final minVis = minOf3(
      resolved.proximal.likelihood,
      resolved.vertex.likelihood,
      resolved.distal.likelihood,
    );
    if (minVis < minVisibility) continue;
    if (best == null || minVis > best.minVisibility) {
      best = (
        proximal: resolved.proximal,
        vertex: resolved.vertex,
        distal: resolved.distal,
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
  JointChain chain = JointChain.leg,
  double switchMargin = sideSwitchMargin,
  double? imageWidth,
  double? imageHeight,
}) {
  final best = selectBetterSide(
    landmarks,
    minVisibility: minVisibility,
    chain: chain,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
  );
  if (best == null || currentSide == null || best.side == currentSide) {
    return best;
  }
  // best is the OTHER side. Find the current side's chain, if still usable.
  final side = currentSide;
  final resolved = chainFor(landmarks, side, chain);
  if (resolved == null) return best;
  if (!inImageBounds(
        resolved.proximal,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      ) ||
      !inImageBounds(
        resolved.vertex,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      ) ||
      !inImageBounds(
        resolved.distal,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      )) {
    return best;
  }
  final currentVis = minOf3(
    resolved.proximal.likelihood,
    resolved.vertex.likelihood,
    resolved.distal.likelihood,
  );
  if (currentVis < minVisibility) return best;
  return best.minVisibility > currentVis + switchMargin
      ? best
      : (
          proximal: resolved.proximal,
          vertex: resolved.vertex,
          distal: resolved.distal,
          minVisibility: currentVis,
          side: side,
        );
}
