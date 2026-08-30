/// Pose inference service (roles.md A-4).
///
/// Bundled **base** pose model in **stream mode** (requirements.md B1/N1):
/// `PoseDetectorOptions()` defaults to the base model, and the mode is set
/// explicitly so stream semantics are never an accident.
///
/// Frames arriving while inference is in flight are dropped — back-pressure
/// by dropping, never queueing. That keeps latency flat and maps directly
/// onto the future Evidence `framesDropped` counter.
library;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class PoseService {
  PoseService()
    : _detector = PoseDetector(
        options: PoseDetectorOptions(mode: PoseDetectionMode.stream),
      );

  final PoseDetector _detector;
  bool _busy = false;
  bool _closed = false;

  bool get busy => _busy;
  bool get closed => _closed;

  /// Processes [image]. Returns `null` when the frame is dropped (inference
  /// busy or service closed) or when inference fails — callers treat all of
  /// these as "no result this frame".
  Future<List<Pose>?> process(InputImage image) async {
    if (_busy || _closed) return null;
    _busy = true;
    try {
      return await _detector.processImage(image);
    } catch (_) {
      return null;
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _detector.close();
  }
}
