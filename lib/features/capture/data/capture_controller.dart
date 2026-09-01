/// CaptureController — the single funnel for camera frames → landmarks →
/// preview state (api-contract.md §state rule 3). Rep-event writing joins
/// this class later with Track A; this milestone is preview only — no
/// counting, calibration, or Evidence.
///
/// Ownership: A.
library;

import 'dart:async' show unawaited;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:reprush/features/capture/camera/coordinates.dart';
import 'package:reprush/features/capture/camera/input_image_adapter.dart';
import 'package:reprush/features/capture/camera/pose_service.dart';
import 'package:reprush/features/capture/camera/squat_landmarks.dart';
import 'package:reprush/features/capture/pipeline/feedback.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/pipeline_trace_recorder.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';
import 'package:reprush/features/capture/pipeline/trace_recorder.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// Where the capture flow currently is.
enum CapturePhase {
  initializing,
  streaming,
  paused,
  denied,
  unavailable,
  failed,
}

/// Low-frequency capture state: phase, processing FPS, tracking availability.
class CaptureStatus {
  const CaptureStatus({
    required this.phase,
    this.fps = 0,
    this.trackingLost = false,
    this.message = '',
  });

  final CapturePhase phase;

  /// Completed inferences per second, over a rolling one-second window.
  final int fps;

  /// True when the squat landmarks have not been reliably observed for a
  /// sustained stretch (B6 red state — preview availability only).
  final bool trackingLost;

  /// Human-readable reason for a problem phase (N9: always shown with an
  /// icon and colour, never colour alone).
  final String message;
}

/// One frame of landmarks in rotated image space, plus the rotated image
/// size the overlay needs to map them onto the preview.
class PoseFrame {
  const PoseFrame({
    required this.points,
    required this.imageSize,
    this.landmarkVisibility,
    this.feedback,
    this.repCount = 0,
    this.activeSideLandmarks,
  });

  final Map<PoseLandmarkType, Offset> points;
  final Size imageSize;

  /// Per-landmark ML Kit likelihood (0.0–1.0) for visibility-aware
  /// rendering. Null in preview-only mode.
  final Map<PoseLandmarkType, double>? landmarkVisibility;

  /// Pipeline coaching state for this frame. Null = no session active —
  /// the overlay falls back to its preview-only look.
  final FeedbackSnapshot? feedback;
  final int repCount;

  /// The hip/knee/ankle of the side the machine is counting from — the
  /// overlay paints these in the feedback colour.
  final Set<PoseLandmarkType>? activeSideLandmarks;
}

class CaptureController extends Notifier<CaptureStatus> {
  /// Sustained unobserved streak (~1 s at the B1 fps floor) before the
  /// tracking-lost state is raised.
  static const int _lostAfterFrames = 15;

  /// High-frequency frame output — consumed via `ValueListenableBuilder` so
  /// 15 fps landmarks never churn the provider/widget tree.
  final ValueNotifier<PoseFrame?> frames = ValueNotifier(null);

  /// High-frequency pipeline output (rep count, phase, cue, calibration
  /// progress) — survives frames where the skeleton is cleared, so the HUD
  /// can still show "Tracking lost" while the overlay paints nothing.
  final ValueNotifier<PipelineFrame?> pipelineFrames = ValueNotifier(null);

  CameraController? get cameraController => _camera;

  CameraController? _camera;
  PoseService? _pose;
  SquatPipeline? _pipeline;
  TraceRecorder? _traceRecorder;

  /// Debug-only pipeline diagnostics (angles, phase, thresholds, side,
  /// per-joint likelihoods, dt) — the tuning-evidence log. Release builds
  /// never allocate it; its content never enters Evidence.
  PipelineTraceRecorder? _diagRecorder;

  bool _starting = false;
  bool _streaming = false;
  int _missStreak = 0;
  int _inferences = 0;
  int _currentFps = 0;
  Stopwatch? _fpsWindow;

  @override
  CaptureStatus build() {
    ref.onDispose(() {
      unawaited(stop());
      frames.dispose();
      pipelineFrames.dispose();
    });
    return const CaptureStatus(phase: CapturePhase.initializing);
  }

  /// True while a counting session is active (preview-only mode otherwise).
  bool get sessionActive => _pipeline != null;

  /// Starts a counting session. While the pipeline is null, `_onPoses`
  /// behaves exactly like preview-only mode.
  void startSession(MovementConfig config) {
    _pipeline?.reset();
    _pipeline = SquatPipeline(config);
    // Debug-only fixture capture — release builds never allocate it.
    _traceRecorder = kDebugMode ? TraceRecorder() : null;
    _diagRecorder = kDebugMode ? PipelineTraceRecorder() : null;
    pipelineFrames.value = null;
  }

  /// Freezes calibration thresholds once enough rest samples exist. The
  /// pump auto-finalizes on the sample-count edge; the UI can also call
  /// this explicitly. Returns false when the attempt was rejected — the
  /// pipeline has already cleared the window for a retry and the reason
  /// is on the next [PipelineFrame].
  bool finalizeCalibration() => _pipeline?.finalizeCalibration() ?? false;

  /// Manual recalibration (debug panel): back to CALIBRATING with a fresh
  /// sample window, machine, counts, and side state cleared.
  void recalibrate() {
    final pipeline = _pipeline;
    if (pipeline == null) return;
    pipeline.reset();
    pipelineFrames.value = null;
  }

  /// Ends the session. Debug traces are exported to the log so they can be
  /// pulled and committed as replay fixtures (never uploaded — §evidence).
  void stopSession() {
    final recorder = _traceRecorder;
    if (recorder != null && recorder.frameCount > 0) {
      debugPrint(
        'RepRush trace: ${recorder.frameCount} frames recorded — '
        'export via debugTraceJson() to build a replay fixture.',
      );
    }
    final diag = _diagRecorder;
    if (diag != null && diag.entryCount > 0) {
      debugPrint(
        'RepRush diagnostics: ${diag.entryCount} entries recorded — '
        'export via exportDiagnosticsToLog() to pull tuning evidence.',
      );
    }
    _pipeline?.reset();
    _pipeline = null;
    _traceRecorder = null;
    _diagRecorder = null;
    pipelineFrames.value = null;
  }

  /// Fixture JSON for the current debug session (null outside debug or
  /// with no frames). Strictly local — never submitted with Evidence.
  String? debugTraceJson() => _traceRecorder?.exportJson();

  /// Diagnostics JSON for the current debug session (null outside debug
  /// or with no entries). Strictly local — never submitted with Evidence.
  String? debugDiagnosticsJson() => _diagRecorder?.exportJson();

  /// Prints the diagnostics JSON to the log in logcat-safe chunks so it
  /// can be pulled with `adb logcat | grep RepRushDiag`. Returns the
  /// number of entries exported (0 outside debug builds).
  int exportDiagnosticsToLog() {
    final json = _diagRecorder?.exportJson();
    if (json == null) return 0;
    const chunkSize = 1000;
    final chunks = (json.length / chunkSize).ceil();
    for (var i = 0; i < chunks; i += 1) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, json.length);
      debugPrint('RepRushDiag ${i + 1}/$chunks: ${json.substring(start, end)}');
    }
    return _diagRecorder?.entryCount ?? 0;
  }

  /// Opens the rear camera and starts the frame → inference pump. Idempotent
  /// while streaming or already starting.
  Future<void> start() async {
    if (state.phase == CapturePhase.streaming || _starting) return;
    _starting = true;
    try {
      // Portrait-locked capture: the rotation formula still runs against
      // the live device orientation — this is not a shortcut around it.
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      final cameras = await availableCameras();
      CameraDescription? back;
      for (final camera in cameras) {
        if (camera.lensDirection == CameraLensDirection.back) {
          back = camera;
          break;
        }
      }
      if (back == null) {
        state = const CaptureStatus(
          phase: CapturePhase.unavailable,
          message: 'No camera was found on this device.',
        );
        return;
      }
      // NV21 on Android: camera_android_camerax streams real NV21 for this
      // format group (see input_image_adapter.dart).
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.nv21,
      );
      await controller.initialize();
      _camera = controller;
      if (_pose == null || _pose!.closed) _pose = PoseService();
      await controller.startImageStream(_onFrame);
      _streaming = true;
      _fpsWindow = Stopwatch()..start();
      state = const CaptureStatus(phase: CapturePhase.streaming);
    } on CameraException catch (e) {
      await _releaseCamera();
      state = switch (e.code) {
        'CameraAccessDenied' ||
        'CameraAccessDeniedWithoutPrompt' ||
        'CameraAccessRestricted' => const CaptureStatus(
          phase: CapturePhase.denied,
          message:
              'Camera access was denied. Allow the camera permission in '
              'system settings, then try again.',
        ),
        _ => CaptureStatus(
          phase: CapturePhase.failed,
          message: 'The camera could not be started: ${e.description}',
        ),
      };
    } catch (e) {
      await _releaseCamera();
      state = CaptureStatus(
        phase: CapturePhase.failed,
        message: 'The camera could not be started: $e',
      );
    } finally {
      _starting = false;
    }
  }

  /// App backgrounded: release the camera but keep the detector warm so
  /// [resume] can reopen quickly.
  Future<void> pause() async {
    if (state.phase != CapturePhase.streaming) return;
    await _releaseCamera();
    _fpsWindow?.stop();
    state = const CaptureStatus(phase: CapturePhase.paused);
  }

  /// App foregrounded again.
  Future<void> resume() async {
    if (state.phase != CapturePhase.paused) return;
    await start();
  }

  /// Full teardown — camera, detector, counters, orientation lock.
  Future<void> stop() async {
    await _releaseCamera();
    await _pose?.close();
    _pose = null;
    stopSession();
    _fpsWindow?.stop();
    _fpsWindow = null;
    _missStreak = 0;
    _inferences = 0;
    _currentFps = 0;
    frames.value = null;
    await SystemChrome.setPreferredOrientations([]);
  }

  void _onFrame(CameraImage image) {
    final camera = _camera;
    final pose = _pose;
    if (camera == null || pose == null || !_streaming) return;
    final input = inputImageFromCameraImage(
      image,
      camera: camera.description,
      deviceOrientation: camera.value.deviceOrientation,
    );
    if (input == null) return;
    // process() returns null for dropped frames (inference busy) —
    // back-pressure by dropping, never queueing (A-4).
    pose.process(input).then((poses) {
      if (_camera == null || !_streaming) return;
      if (poses == null) return;
      _onPoses(
        poses,
        image,
        camera.description,
        camera.value.deviceOrientation,
      );
    });
  }

  void _onPoses(
    List<Pose> poses,
    CameraImage image,
    CameraDescription camera,
    DeviceOrientation orientation,
  ) {
    // Processing FPS over a rolling one-second window.
    _inferences += 1;
    final window = _fpsWindow;
    if (window != null && window.elapsedMilliseconds >= 1000) {
      _currentFps = (_inferences * 1000 / window.elapsedMilliseconds).round();
      _inferences = 0;
      window
        ..reset()
        ..start();
    }

    final degrees = rotationDegrees(
      sensorOrientation: camera.sensorOrientation,
      deviceOrientation: orientation,
      frontFacing: camera.lensDirection == CameraLensDirection.front,
    );
    final pose = poses.isEmpty ? null : poses.first;

    final pipeline = _pipeline;
    if (pipeline != null) {
      _onPosesWithPipeline(pipeline, pose, image, degrees);
      return;
    }

    final observed = pose == null
        ? const <({PoseLandmarkType type, double likelihood})>[]
        : [
            for (final landmark in pose.landmarks.values)
              (type: landmark.type, likelihood: landmark.likelihood),
          ];

    PoseFrame? drawable;
    if (degrees != null && pose != null && squatLandmarksObserved(observed)) {
      drawable = PoseFrame(
        points: {
          for (final landmark in pose.landmarks.values)
            landmark.type: Offset(landmark.x, landmark.y),
        },
        imageSize: rotatedImageSize(
          Size(image.width.toDouble(), image.height.toDouble()),
          degrees,
        ),
      );
    }
    applyPose(drawable: drawable);
  }

  /// Session path: landmarks cross the purity boundary into the pipeline,
  /// and the pipeline's side selection decides what is drawable. A null
  /// selection clears the skeleton immediately — never a stale pose (§10c).
  void _onPosesWithPipeline(
    SquatPipeline pipeline,
    Pose? pose,
    CameraImage image,
    int? degrees,
  ) {
    // Rotated image dimensions — the pipeline's frame-bounds check treats
    // out-of-bounds landmarks (stale ML Kit extrapolations after the
    // athlete exits frame) as unusable regardless of likelihood.
    final rotated = degrees == null
        ? null
        : rotatedImageSize(
            Size(image.width.toDouble(), image.height.toDouble()),
            degrees,
          );
    final landmarkFrame = LandmarkFrame(
      landmarks: {
        if (pose != null)
          for (final landmark in pose.landmarks.values)
            landmark.type.name: (
              x: landmark.x,
              y: landmark.y,
              likelihood: landmark.likelihood,
            ),
      },
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      imageWidth: rotated?.width,
      imageHeight: rotated?.height,
    );
    _traceRecorder?.record(landmarkFrame);

    final result = pipeline.tick(landmarkFrame);
    _diagRecorder?.recordTick(frame: landmarkFrame, result: result);
    pipelineFrames.value = result;
    // Auto-finalize on the sample-count edge (~2 s of steady standing). A
    // rejection clears the window inside the pipeline and re-collects; the
    // outcome — accepted AND rejected — goes to the diagnostics trace so
    // the rejection evidence survives the clearing.
    if (pipeline.calibrating && pipeline.hasEnoughCalibrationSamples) {
      pipeline.finalizeCalibration();
      final outcome = pipeline.lastCalibrationOutcome;
      if (outcome != null) {
        _diagRecorder?.recordCalibration(outcome);
      }
    }

    PoseFrame? drawable;
    if (degrees != null && pose != null && result.selectedSide != null) {
      drawable = PoseFrame(
        points: {
          for (final landmark in pose.landmarks.values)
            landmark.type: Offset(landmark.x, landmark.y),
        },
        imageSize: rotatedImageSize(
          Size(image.width.toDouble(), image.height.toDouble()),
          degrees,
        ),
        landmarkVisibility: {
          for (final landmark in pose.landmarks.values)
            landmark.type: landmark.likelihood,
        },
        feedback: result.feedback,
        repCount: result.repCount,
        activeSideLandmarks: _activeSideLandmarks(result.selectedSide!),
      );
    }
    applyPose(drawable: drawable);
  }

  /// The counted side's hip-knee-ankle chain, for overlay colouring.
  Set<PoseLandmarkType> _activeSideLandmarks(String side) => side == 'left'
      ? const {
          PoseLandmarkType.leftHip,
          PoseLandmarkType.leftKnee,
          PoseLandmarkType.leftAnkle,
        }
      : const {
          PoseLandmarkType.rightHip,
          PoseLandmarkType.rightKnee,
          PoseLandmarkType.rightAnkle,
        };

  /// Applies one inference result to the drawable-frame state.
  ///
  /// A frame is drawable only when that very frame carries the full squat
  /// chain at threshold — anything else clears the overlay immediately, so
  /// the UI never shows a stale or jumbled skeleton while tracking is lost.
  @visibleForTesting
  void applyPose({required PoseFrame? drawable}) {
    if (drawable != null) {
      // Tracked: publish the current frame and reset the miss streak.
      _missStreak = 0;
      frames.value = drawable;
    } else {
      // Unobserved: drop the previous frame now — it is never reused while
      // tracking is lost. The lost banner itself waits for a sustained
      // streak so brief occlusions don't flicker the message.
      frames.value = null;
      _missStreak += 1;
    }

    final lost = _missStreak >= _lostAfterFrames;
    final current = state;
    if (current.phase != CapturePhase.streaming) return;
    if (current.trackingLost != lost || current.fps != _currentFps) {
      state = CaptureStatus(
        phase: CapturePhase.streaming,
        fps: _currentFps,
        trackingLost: lost,
      );
    }
  }

  Future<void> _releaseCamera() async {
    final camera = _camera;
    _camera = null;
    _streaming = false;
    if (camera == null) return;
    try {
      if (camera.value.isInitialized) {
        await camera.stopImageStream();
      }
    } catch (_) {
      // A failed stream stop must never block disposal.
    }
    try {
      await camera.dispose();
    } catch (_) {
      // Idempotent dispose — teardown races are expected on lifecycle edges.
    }
  }
}
