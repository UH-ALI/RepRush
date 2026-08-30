/// CameraImage → ML Kit `InputImage` (roles.md A-3).
///
/// Follows the current `google_mlkit_commons` documented camera adapter,
/// with one deliberate deviation: `camera_android_camerax` delivers real
/// NV21 data for an `ImageFormatGroup.nv21` controller while still reporting
/// `image.format` as `yuv420` (CameraX `OUTPUT_IMAGE_FORMAT_NV21`). The
/// format here is therefore declared by construction — never inferred from
/// `image.format` — and the single-plane NV21 contract is asserted instead.
/// No Y/U/V planes are ever concatenated.
library;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:reprush/features/capture/camera/coordinates.dart';

/// Builds an [InputImage] from a streamed [image], or `null` when the frame
/// cannot be described correctly (unknown rotation, wrong plane layout) —
/// such frames are dropped, never guessed.
InputImage? inputImageFromCameraImage(
  CameraImage image, {
  required CameraDescription camera,
  required DeviceOrientation deviceOrientation,
}) {
  // Rotation — the google_mlkit_commons example formula:
  // rear = sensor - device, front = sensor + device, mod 360.
  final degrees = rotationDegrees(
    sensorOrientation: camera.sensorOrientation,
    deviceOrientation: deviceOrientation,
    frontFacing: camera.lensDirection == CameraLensDirection.front,
  );
  if (degrees == null) return null;
  final rotation = InputImageRotationValue.fromRawValue(degrees);
  if (rotation == null) return null;

  // NV21 streams carry exactly one plane; anything else means the NV21
  // contract is broken and the frame must not be handed to ML Kit.
  if (image.planes.length != 1) return null;
  final plane = image.planes.first;

  return InputImage.fromBytes(
    bytes: plane.bytes,
    metadata: InputImageMetadata(
      size: Size(image.width.toDouble(), image.height.toDouble()),
      rotation: rotation,
      // Declared by construction — see library doc.
      format: InputImageFormat.nv21,
      bytesPerRow: plane.bytesPerRow,
    ),
  );
}
