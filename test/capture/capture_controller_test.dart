/// Controller tests for the drawable-frame policy: the overlay may only
/// show the current frame, and it must clear the instant the squat chain
/// disappears — never a stale skeleton. No camera, no ML Kit objects.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:reprush/features/capture/data/capture_controller.dart';
import 'package:reprush/features/capture/data/capture_providers.dart';

/// Skips camera start — the controller is exercised through [applyPose]
/// with a streaming phase so status transitions are live.
class _StreamingCaptureController extends CaptureController {
  @override
  CaptureStatus build() => const CaptureStatus(phase: CapturePhase.streaming);
}

const _imageSize = Size(720, 1280);

PoseFrame _trackedFrame() => const PoseFrame(
  points: {
    PoseLandmarkType.leftHip: Offset(300, 600),
    PoseLandmarkType.rightHip: Offset(420, 600),
    PoseLandmarkType.leftKnee: Offset(300, 800),
    PoseLandmarkType.rightKnee: Offset(420, 800),
    PoseLandmarkType.leftAnkle: Offset(300, 1000),
    PoseLandmarkType.rightAnkle: Offset(420, 1000),
  },
  imageSize: _imageSize,
);

void main() {
  late ProviderContainer container;
  late CaptureController controller;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        captureControllerProvider.overrideWith(_StreamingCaptureController.new),
      ],
    );
    addTearDown(container.dispose);
    controller = container.read(captureControllerProvider.notifier);
  });

  test('a tracked frame is published and tracking stays green', () {
    final frame = _trackedFrame();
    controller.applyPose(drawable: frame);

    expect(controller.frames.value, frame);
    final status = container.read(captureControllerProvider);
    expect(status.trackingLost, isFalse);
    expect(status.phase, CapturePhase.streaming);
  });

  test('losing the squat chain clears the overlay immediately', () {
    final frame = _trackedFrame();
    controller.applyPose(drawable: frame);
    expect(controller.frames.value, frame);

    // The very first frame without the required landmarks must drop the
    // previous skeleton — it is never reused while tracking is lost.
    controller.applyPose(drawable: null);
    expect(controller.frames.value, isNull);
  });

  test('a sustained loss keeps the overlay clear and raises tracking-lost', () {
    controller.applyPose(drawable: _trackedFrame());

    // ~1 s of unobserved frames at the B1 fps floor.
    for (var i = 0; i < 15; i += 1) {
      controller.applyPose(drawable: null);
    }

    final status = container.read(captureControllerProvider);
    expect(status.trackingLost, isTrue);
    expect(status.phase, CapturePhase.streaming);
    expect(controller.frames.value, isNull);

    // Recovery publishes the current frame again and clears the lost state.
    final recovered = _trackedFrame();
    controller.applyPose(drawable: recovered);
    expect(controller.frames.value, recovered);
    expect(container.read(captureControllerProvider).trackingLost, isFalse);
  });
}
