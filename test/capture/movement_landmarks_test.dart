/// Unit tests for movement tracking availability — pure predicate over
/// chain-derived landmark requirements, fabricated landmark records, no
/// ML Kit objects.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:reprush/features/capture/camera/movement_landmarks.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';

List<({PoseLandmarkType type, double likelihood})> _chain(
  JointChain chain,
  double likelihood,
) =>
    [
      for (final type in requiredLandmarks(chain))
        (type: type, likelihood: likelihood),
    ];

void main() {
  group('requiredLandmarks', () {
    test('the leg chain requires hip-knee-ankle on both sides', () {
      expect(requiredLandmarks(JointChain.leg), {
        PoseLandmarkType.leftHip,
        PoseLandmarkType.leftKnee,
        PoseLandmarkType.leftAnkle,
        PoseLandmarkType.rightHip,
        PoseLandmarkType.rightKnee,
        PoseLandmarkType.rightAnkle,
      });
    });

    test('the arm chain requires shoulder-elbow-wrist on both sides', () {
      expect(requiredLandmarks(JointChain.arm), {
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.leftElbow,
        PoseLandmarkType.leftWrist,
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.rightElbow,
        PoseLandmarkType.rightWrist,
      });
    });

    test('leg and arm chains are disjoint', () {
      expect(
        requiredLandmarks(JointChain.leg)
            .intersection(requiredLandmarks(JointChain.arm)),
        isEmpty,
      );
    });
  });

  group('chainLandmarksObserved', () {
    test('the full leg chain above the floor is observed', () {
      expect(
        chainLandmarksObserved(JointChain.leg, _chain(JointChain.leg, 0.9)),
        isTrue,
      );
      expect(
        chainLandmarksObserved(
          JointChain.leg,
          _chain(JointChain.leg, minLandmarkLikelihood),
        ),
        isTrue,
      );
    });

    test('the full arm chain above the floor is observed', () {
      expect(
        chainLandmarksObserved(JointChain.arm, _chain(JointChain.arm, 0.9)),
        isTrue,
      );
    });

    test('a missing ankle breaks leg tracking', () {
      final observed = _chain(JointChain.leg, 0.9)
        ..removeWhere((landmark) => landmark.type == PoseLandmarkType.leftAnkle);
      expect(
        chainLandmarksObserved(JointChain.leg, observed),
        isFalse,
      );
    });

    test('a leg chain does not satisfy arm tracking', () {
      // Legs visible, arms never seen — the arm chain must not count.
      expect(
        chainLandmarksObserved(JointChain.arm, _chain(JointChain.leg, 0.9)),
        isFalse,
      );
    });

    test('no pose means nothing is observed', () {
      expect(chainLandmarksObserved(JointChain.leg, const []), isFalse);
      expect(chainLandmarksObserved(JointChain.arm, const []), isFalse);
    });

    test('landmarks below the likelihood floor are not reliable', () {
      expect(
        chainLandmarksObserved(
          JointChain.leg,
          _chain(JointChain.leg, minLandmarkLikelihood - 0.01),
        ),
        isFalse,
      );
    });
  });
}
