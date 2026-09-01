/// Unit tests for higher-visibility side selection.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/side_selector.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

Lm lm(double likelihood) => (x: 10, y: 20, likelihood: likelihood);

/// A landmark at an explicit position — for frame-bounds checks.
Lm lmAt(double x, double y, double likelihood) =>
    (x: x, y: y, likelihood: likelihood);

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

  group('frame bounds', () {
    test('an out-of-bounds landmark is rejected even at high likelihood', () {
      // Stale extrapolated landmark: well outside the image, yet its
      // likelihood skims above the usability floor.
      final landmarks = sides(left: 0.9, right: 0.6);
      landmarks['leftAnkle'] = lmAt(500, 20, 0.95);
      final picked = selectBetterSide(
        landmarks,
        imageWidth: 480,
        imageHeight: 640,
      );
      expect(picked!.side, 'right');
    });

    test('negative coordinates are rejected even at high likelihood', () {
      final landmarks = sides(left: 0.6, right: 0.9);
      landmarks['rightKnee'] = lmAt(-5, 20, 0.95);
      final picked = selectBetterSide(
        landmarks,
        imageWidth: 480,
        imageHeight: 640,
      );
      expect(picked!.side, 'left');
    });

    test('both chains out of bounds means tracking lost', () {
      final landmarks = sides(left: 0.9, right: 0.9);
      landmarks['leftHip'] = lmAt(900, 20, 0.9);
      landmarks['rightHip'] = lmAt(900, 20, 0.9);
      expect(
        selectBetterSide(landmarks, imageWidth: 480, imageHeight: 640),
        isNull,
      );
    });

    test('no image dimensions means no bounds enforcement', () {
      // Synthetic fixtures carry no dimensions — behaviour must not change.
      final landmarks = sides(left: 0.9, right: 0.6);
      landmarks['leftAnkle'] = lmAt(5000, 20, 0.95);
      expect(selectBetterSide(landmarks)!.side, 'left');
    });

    test('sideVisibilities treats an out-of-bounds chain as unusable', () {
      final landmarks = sides(left: 0.9, right: 0.6);
      landmarks['leftAnkle'] = lmAt(500, 20, 0.95);
      final vis = sideVisibilities(
        landmarks,
        imageWidth: 480,
        imageHeight: 640,
      );
      expect(vis.left, isNull);
      expect(vis.right, closeTo(0.6, 1e-9));
    });

    test('sticky selection switches when the current chain drifts outside', () {
      final landmarks = sides(left: 0.9, right: 0.8);
      landmarks['leftAnkle'] = lmAt(-50, 20, 0.9);
      final picked = stickySelectSide(
        landmarks,
        currentSide: 'left',
        imageWidth: 480,
        imageHeight: 640,
      );
      expect(picked!.side, 'right');
    });
  });

  group('sideVisibilities', () {
    test('reports the min-of-chain likelihood per side', () {
      final landmarks = sides(left: 0.9, right: 0.6);
      landmarks['rightAnkle'] = lm(0.3);
      final vis = sideVisibilities(landmarks);
      expect(vis.left, closeTo(0.9, 1e-9));
      expect(vis.right, closeTo(0.3, 1e-9));
    });

    test('an incomplete chain reports null, not zero', () {
      final landmarks = sides(left: 0.9, right: 0.9)..remove('leftKnee');
      final vis = sideVisibilities(landmarks);
      expect(vis.left, isNull);
      expect(vis.right, closeTo(0.9, 1e-9));
    });
  });

  group('stickySelectSide', () {
    test('bootstraps to the strongest usable side', () {
      final picked = stickySelectSide(sides(left: 0.9, right: 0.6));
      expect(picked!.side, 'left');
    });

    test('keeps the current side within the switch margin', () {
      // Right is better, but only by 0.05 < 0.10 margin — no flicker.
      final picked = stickySelectSide(
        sides(left: 0.80, right: 0.85),
        currentSide: 'left',
      );
      expect(picked!.side, 'left');
    });

    test('switches when the other side beats the margin', () {
      final picked = stickySelectSide(
        sides(left: 0.80, right: 0.95),
        currentSide: 'left',
      );
      expect(picked!.side, 'right');
    });

    test('switches instantly when the current side drops below the floor', () {
      // A genuine turn-around never waits on a margin.
      final picked = stickySelectSide(
        sides(left: 0.3, right: 0.55),
        currentSide: 'left',
      );
      expect(picked!.side, 'right');
    });

    test('switches instantly when the current chain loses a landmark', () {
      final landmarks = sides(left: 0.9, right: 0.8)..remove('leftAnkle');
      final picked = stickySelectSide(landmarks, currentSide: 'left');
      expect(picked!.side, 'right');
    });

    test('neither side usable means tracking lost', () {
      expect(
        stickySelectSide(sides(left: 0.2, right: 0.3), currentSide: 'left'),
        isNull,
      );
    });
  });
}
