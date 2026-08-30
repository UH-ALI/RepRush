/// Capture feature providers (feature-scoped — §state rule 1).
///
/// Ownership: A.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/features/capture/data/capture_controller.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';

/// The capture funnel: camera frames → landmarks → preview state. Rep-event
/// writing (§state rule 3) joins this controller later with Track A.
final captureControllerProvider =
    NotifierProvider<CaptureController, CaptureStatus>(CaptureController.new);

/// High-frequency frame output — watched once, consumed per frame via
/// `ValueListenableBuilder` so landmarks never churn provider rebuilds.
final poseFramesProvider = Provider<ValueNotifier<PoseFrame?>>((ref) {
  return ref.watch(captureControllerProvider.notifier).frames;
});

/// High-frequency pipeline output (rep count, cue, calibration progress) —
/// the HUD's source; non-null only while a counting session is active.
final pipelineFramesProvider = Provider<ValueNotifier<PipelineFrame?>>((ref) {
  return ref.watch(captureControllerProvider.notifier).pipelineFrames;
});
