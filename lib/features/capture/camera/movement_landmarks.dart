/// Movement tracking availability (roles.md A-9 preview subset) — which
/// landmarks a movement's joint chain needs, and whether they are
/// reliably observed. The rep state machine and thresholds stay in the
/// pipeline and out of this file.
///
/// Ownership: A.
library;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';

/// PoseLandmarkType lookup by landmark key (`'leftHip'`, `'rightWrist'`)
/// — the same string keys the pipeline's [LandmarkFrame] carries, so both
/// layers resolve from one naming scheme.
final Map<String, PoseLandmarkType> poseLandmarkByName = {
  for (final type in PoseLandmarkType.values) type.name: type,
};

/// The landmarks a movement measuring on [chain] requires — the chain's
/// proximal → vertex → distal triplet on both sides.
Set<PoseLandmarkType> requiredLandmarks(JointChain chain) => {
      for (final key in chain.landmarkKeys) poseLandmarkByName[key]!,
    };

/// Likelihood floor for "reliably observed". `inFrameLikelihood` is strictly
/// a framing signal (api-contract.md §evidence caveat), so it is a proxy
/// here — a Day-2-style starting guess, tunable, not a contract.
const double minLandmarkLikelihood = 0.5;

/// True when every landmark the [chain] requires is present at or above
/// [minLikelihood].
///
/// Accepts plain records so the predicate stays unit-testable without
/// constructing ML Kit objects.
bool chainLandmarksObserved(
  JointChain chain,
  Iterable<({PoseLandmarkType type, double likelihood})> observed, {
  double minLikelihood = minLandmarkLikelihood,
}) {
  final reliable = {
    for (final landmark in observed)
      if (landmark.likelihood >= minLikelihood) landmark.type,
  };
  return requiredLandmarks(chain).every(reliable.contains);
}
