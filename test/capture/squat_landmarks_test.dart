/// Unit tests for squat tracking availability — pure predicate, fabricated
/// landmark records, no ML Kit objects.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:reprush/features/capture/camera/squat_landmarks.dart';

List<({PoseLandmarkType type, double likelihood})> _chain(double likelihood) =>
    [
      for (final type in squatRequiredLandmarks)
        (type: type, likelihood: likelihood),
    ];

void main() {
  test('the full hip-knee-ankle chain above the floor is observed', () {
    expect(squatLandmarksObserved(_chain(0.9)), isTrue);
    expect(squatLandmarksObserved(_chain(squatMinLikelihood)), isTrue);
  });

  test('a missing ankle breaks squat tracking', () {
    final observed = _chain(0.9)
      ..removeWhere((landmark) => landmark.type == PoseLandmarkType.leftAnkle);
    expect(squatLandmarksObserved(observed), isFalse);
  });

  test('no pose means nothing is observed', () {
    expect(squatLandmarksObserved(const []), isFalse);
  });

  test('landmarks below the likelihood floor are not reliable', () {
    expect(squatLandmarksObserved(_chain(squatMinLikelihood - 0.01)), isFalse);
  });
}
