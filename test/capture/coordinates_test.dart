/// Unit tests for the camera → ML Kit coordinate math — rotation, rotated
/// size, and the centre-crop overlay transform.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/camera/coordinates.dart';

void main() {
  group('rotationDegrees', () {
    test('rear camera, portrait-locked: formula reduces to the sensor', () {
      expect(
        rotationDegrees(
          sensorOrientation: 90,
          deviceOrientation: DeviceOrientation.portraitUp,
          frontFacing: false,
        ),
        90,
      );
      expect(
        rotationDegrees(
          sensorOrientation: 270,
          deviceOrientation: DeviceOrientation.portraitUp,
          frontFacing: false,
        ),
        270,
      );
    });

    test('rear camera subtracts the device rotation', () {
      expect(
        rotationDegrees(
          sensorOrientation: 90,
          deviceOrientation: DeviceOrientation.landscapeLeft,
          frontFacing: false,
        ),
        0,
      );
      expect(
        rotationDegrees(
          sensorOrientation: 0,
          deviceOrientation: DeviceOrientation.landscapeRight,
          frontFacing: false,
        ),
        90,
      );
    });

    test('front camera adds the device rotation', () {
      expect(
        rotationDegrees(
          sensorOrientation: 270,
          deviceOrientation: DeviceOrientation.landscapeLeft,
          frontFacing: true,
        ),
        0,
      );
    });
  });

  group('rotatedImageSize', () {
    test('0/180 keep the sides; 90/270 swap them', () {
      const raw = Size(1280, 720);
      expect(rotatedImageSize(raw, 0), raw);
      expect(rotatedImageSize(raw, 180), raw);
      expect(rotatedImageSize(raw, 90), const Size(720, 1280));
      expect(rotatedImageSize(raw, 270), const Size(720, 1280));
    });
  });

  group('imageToViewPoint', () {
    test('uniform scale maps landmarks proportionally', () {
      final p = imageToViewPoint(
        const Offset(100, 200),
        const Size(720, 1280),
        const Size(360, 640),
      );
      expect(p, const Offset(50, 100));
    });

    test('cover fit crops symmetrically on the overflowing axis', () {
      // Rotated 1280x720 inside a 360x640 box: height drives the scale and
      // the horizontal overflow is split evenly.
      const view = Size(360, 640);
      const image = Size(1280, 720);
      final scale = 640 / 720;
      final origin = imageToViewPoint(Offset.zero, image, view);
      expect(origin.dy, 0);
      expect(origin.dx, closeTo((360 - 1280 * scale) / 2, 1e-9));
      // The mapped image still covers the whole view width.
      final right = imageToViewPoint(Offset(image.width, 0), image, view);
      expect(right.dx, closeTo(origin.dx + 1280 * scale, 1e-9));
      expect(right.dx, greaterThanOrEqualTo(view.width));
    });
  });
}
