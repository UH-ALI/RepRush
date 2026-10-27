/// Per-frame posture check behind [RepContext] — plain geometry on the joint
/// chain the pipeline already selected, so it needs no extra landmarks and
/// no body-size reference (arm length normalises it).
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'dart:math' as math;

import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// How far BELOW the shoulder the wrist may be, in arm lengths, before the
/// frame counts as "hands not on the bar". Measured on a real pull-up set:
/// worst frame of any real rep +0.06, any hand-drop reaches -0.85 or lower;
/// -0.3 sits well clear of both.
const double minWristAboveShoulder = -0.3;

/// Same idea against the elbow (forearm pointing up): real reps stayed at
/// +0.31 or more, hand-drops went to -0.21 or lower.
const double minWristAboveElbow = 0.1;

/// Whether this frame satisfies the movement's posture rule. Frames where the
/// rule cannot be evaluated (a joint missing, a zero-length arm) do not veto:
/// tracking loss is handled elsewhere and must not cancel good reps.
bool frameContextOk(
  RepContext context,
  Map<String, Lm> landmarks,
  String side,
) {
  switch (context) {
    case RepContext.none:
      return true;
    case RepContext.handsAboveShoulders:
      final s = landmarks['${side}Shoulder'];
      final e = landmarks['${side}Elbow'];
      final w = landmarks['${side}Wrist'];
      if (s == null || e == null || w == null) return true;
      final arm = _dist(s, e) + _dist(e, w);
      if (arm <= 0) return true;
      // Image y grows downward: "above" means a smaller y.
      final wristAboveShoulder = (s.y - w.y) / arm;
      final wristAboveElbow = (e.y - w.y) / arm;
      return wristAboveShoulder >= minWristAboveShoulder &&
          wristAboveElbow >= minWristAboveElbow;
  }
}

double _dist(Lm a, Lm b) {
  final dx = a.x - b.x;
  final dy = a.y - b.y;
  return math.sqrt(dx * dx + dy * dy);
}
