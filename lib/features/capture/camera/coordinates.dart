/// Camera → ML Kit coordinate math (supports roles.md A-3).
///
/// Rotation follows the documented `google_mlkit_commons` camera adapter —
/// rear-facing compensation is `sensor - device`, front-facing is
/// `sensor + device`, both mod 360. It is a formula, never a raw
/// sensor-orientation passthrough.
///
/// ML Kit returns landmarks in the *rotated* image space; the overlay maps
/// them onto the centre-cropped preview box.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';

/// Device orientation → degrees, per the `google_mlkit_commons` example.
const Map<DeviceOrientation, int> deviceOrientationDegrees = {
  DeviceOrientation.portraitUp: 0,
  DeviceOrientation.landscapeLeft: 90,
  DeviceOrientation.portraitDown: 180,
  DeviceOrientation.landscapeRight: 270,
};

/// Input-image rotation for ML Kit, in degrees (0/90/180/270).
///
/// Returns `null` when the compensation is not a right angle — such frames
/// must be dropped rather than guessed.
int? rotationDegrees({
  required int sensorOrientation,
  required DeviceOrientation deviceOrientation,
  required bool frontFacing,
}) {
  final device = deviceOrientationDegrees[deviceOrientation];
  if (device == null) return null;
  final compensation = frontFacing
      ? (sensorOrientation + device) % 360
      : (sensorOrientation - device + 360) % 360;
  if (compensation % 90 != 0) return null;
  return compensation;
}

/// The camera frame size after ML Kit applies [rotation] degrees — 90°/270°
/// swap width and height.
Size rotatedImageSize(Size raw, int rotation) {
  return switch (rotation) {
    90 || 270 => Size(raw.height, raw.width),
    _ => raw,
  };
}

/// Maps a landmark from rotated image space into preview-widget space.
///
/// The camera preview centre-crops to fill its box ("cover" fit), so the
/// image is scaled by the larger of the two axis ratios and the overflow is
/// distributed evenly on both sides.
Offset imageToViewPoint(Offset point, Size rotatedImage, Size view) {
  final scale = math.max(
    view.width / rotatedImage.width,
    view.height / rotatedImage.height,
  );
  final dx = (view.width - rotatedImage.width * scale) / 2;
  final dy = (view.height - rotatedImage.height * scale) / 2;
  return Offset(point.dx * scale + dx, point.dy * scale + dy);
}
