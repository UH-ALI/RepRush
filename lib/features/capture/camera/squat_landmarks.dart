/// Squat tracking availability (roles.md A-9 preview subset).
///
/// Milestone scope: availability only — whether the landmarks a squat needs
/// can be reliably observed. The rep state machine and thresholds come later
/// with Track A and stay out of this file.
library;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// The hip–knee–ankle chain on both sides — the landmarks a squat requires.
const Set<PoseLandmarkType> squatRequiredLandmarks = {
  PoseLandmarkType.leftHip,
  PoseLandmarkType.leftKnee,
  PoseLandmarkType.leftAnkle,
  PoseLandmarkType.rightHip,
  PoseLandmarkType.rightKnee,
  PoseLandmarkType.rightAnkle,
};

/// Likelihood floor for "reliably observed". `inFrameLikelihood` is strictly
/// a framing signal (api-contract.md §evidence caveat), so it is a proxy
/// here — a Day-2-style starting guess, tunable, not a contract.
const double squatMinLikelihood = 0.5;

/// True when every required squat landmark is present at or above
/// [minLikelihood].
///
/// Accepts plain records so the predicate stays unit-testable without
/// constructing ML Kit objects.
bool squatLandmarksObserved(
  Iterable<({PoseLandmarkType type, double likelihood})> observed, {
  double minLikelihood = squatMinLikelihood,
}) {
  final reliable = {
    for (final landmark in observed)
      if (landmark.likelihood >= minLikelihood) landmark.type,
  };
  return squatRequiredLandmarks.every(reliable.contains);
}
