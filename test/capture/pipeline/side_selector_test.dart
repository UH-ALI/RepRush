/// Unit tests for higher-visibility side selection.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/side_selector.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

Lm lm(double likelihood) => (x: 10, y: 20, likelihood: likelihood);

Map<String, Lm> sides({required double left, required double right}) => {
  'leftHip': lm(left),
  'leftKnee': lm(left),
  'leftAnkle': lm(left),
  'rightHip': lm(right),
  'rightKnee': lm(right),
  'rightAnkle': lm(right),
};

void main() {
  test('the left side wins when it is more visible', () {
    final picked = selectBetterSide(sides(left: 0.9, right: 0.6));
    expect(picked, isNotNull);
    expect(picked!.side, 'left');
    expect(picked.minVisibility, closeTo(0.9, 1e-9));
  });

  test('the right side wins when it is more visible', () {
    final picked = selectBetterSide(sides(left: 0.55, right: 0.85));
    expect(picked!.side, 'right');
  });

  test('one usable side still tracks when the other is occluded', () {
    final picked = selectBetterSide(sides(left: 0.2, right: 0.7));
    expect(picked!.side, 'right');
  });

  test('a tied visibility picks a side deterministically', () {
    final picked = selectBetterSide(sides(left: 0.8, right: 0.8));
    expect(picked, isNotNull);
    expect(['left', 'right'], contains(picked!.side));
  });

  test('both sides below the threshold means tracking lost', () {
    expect(selectBetterSide(sides(left: 0.4, right: 0.49)), isNull);
  });

  test('the weakest landmark in the chain decides usability', () {
    final landmarks = sides(left: 0.9, right: 0.9);
    // Occlude the left ankle only — its minimum drops below the floor.
    landmarks['leftAnkle'] = lm(0.3);
    final picked = selectBetterSide(landmarks);
    expect(picked!.side, 'right');
    expect(picked.minVisibility, closeTo(0.9, 1e-9));
  });

  test('a missing landmark disqualifies that side', () {
    final landmarks = sides(left: 0.9, right: 0.9)..remove('rightKnee');
    final picked = selectBetterSide(landmarks);
    expect(picked!.side, 'left');
  });
}
