/// CaptureController — the single funnel for camera frames → landmarks →
/// preview state (api-contract.md §state rule 3). Sole writer of rep
/// events (§state rule 3): retains every `justEmitted` into a set-local
/// list, accumulates frame/dropped counters, and assembles Evidence
/// through [EvidenceBuilder] on `finishSet`.
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
import 'package:reprush/features/capture/camera/movement_landmarks.dart';
import 'package:reprush/features/capture/camera/pose_service.dart';
import 'package:reprush/features/capture/pipeline/evidence.dart';
import 'package:reprush/features/capture/pipeline/feedback.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/pipeline_trace_recorder.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';
import 'package:reprush/features/capture/pipeline/rep_pipeline.dart';
import 'package:reprush/features/capture/pipeline/trace_recorder.dart';
import 'package:reprush/features/capture/pipeline/types.dart';
import 'package:reprush/models/models.dart';

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

  /// True when the required landmarks have not been reliably observed for
  /// a sustained stretch (B6 red state — preview availability only).
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
  RepPipeline? _pipeline;
  TraceRecorder? _traceRecorder;

  /// Debug-only pipeline diagnostics (angles, phase, thresholds, side,
  /// per-joint likelihoods, dt) — the tuning-evidence log. Release builds
  /// never allocate it; its content never enters Evidence.
  PipelineTraceRecorder? _diagRecorder;

  /// Monotonic session clock — the ONLY time source for Evidence
  /// timestamps (schema.ts: every `*Ms` is an offset from client session
  /// start). Started in [startSession] (which runs after the
  /// `/session/start` response has already arrived — the widget mounts
  /// only when `session != null`). Not `DateTime.now()`, not the
  /// returned `serverStartMs`, not the rolling FPS window.
  Stopwatch? _sessionClock;

  /// Completed reps retained for the current set — the single list
  /// [EvidenceBuilder] consumes. Appended on every `justEmitted`.
  final List<RepEvent> _repEvents = [];

  /// Set-level capture metrics — accumulated during an active session,
  /// reset in [startSession], frozen on [finishSet].
  int _framesTotal = 0;
  int _framesDropped = 0;

  bool _starting = false;
  bool _streaming = false;
  CameraLensDirection _lensDirection = CameraLensDirection.back;
  int _missStreak = 0;
  int _inferences = 0;
  int _currentFps = 0;
  Stopwatch? _fpsWindow;

  /// True after the first calibration-frame coordinate-space diagnostic
  /// has been logged. Temporary instrumentation — remove before shipping.
  bool _calibDiagLogged = false;

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
  ///
  /// The monotonic [Stopwatch] starts here, which is after the
  /// `/session/start` response has arrived (the widget mounts only when
  /// `session != null`). This is what makes every downstream timestamp
  /// a valid offset rather than an epoch.
  void startSession(MovementConfig config) {
    _pipeline?.reset();
    _pipeline = RepPipeline(config);
    _sessionClock = Stopwatch()..start();
    _repEvents.clear();
    _framesTotal = 0;
    _framesDropped = 0;
    _calibDiagLogged = false;
    // Debug-only fixture capture — release builds never allocate it.
    _traceRecorder = kDebugMode ? TraceRecorder() : null;
    _diagRecorder = kDebugMode
        ? PipelineTraceRecorder(chain: config.chain)
        : null;
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
    _sessionClock?.stop();
    _sessionClock = null;
    _repEvents.clear();
    _framesTotal = 0;
    _framesDropped = 0;
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

  /// Opens the selected camera and starts the frame → inference pump.
  /// Idempotent while streaming or already starting.
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
      CameraDescription? selected;
      for (final camera in cameras) {
        if (camera.lensDirection == _lensDirection) {
          selected = camera;
          break;
        }
      }
      if (selected == null) {
        state = const CaptureStatus(
          phase: CapturePhase.unavailable,
          message: 'No camera was found on this device.',
        );
        return;
      }
      // NV21 on Android: camera_android_camerax streams real NV21 for this
      // format group (see input_image_adapter.dart).
      final controller = CameraController(
        selected,
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

  /// Switches between the front and rear cameras without resetting the
  /// active movement pipeline or its evidence.
  Future<void> switchCamera() async {
    if (_starting || state.phase != CapturePhase.streaming) return;
    _lensDirection = _lensDirection == CameraLensDirection.back
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    await _releaseCamera();
    state = const CaptureStatus(phase: CapturePhase.initializing);
    await start();
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
    // back-pressure by dropping, never queueing (A-4). Count as a
    // set-level dropped frame when a session is active (Evidence's
    // framesDropped).
    pose.process(input).then((poses) {
      if (_camera == null || !_streaming) return;
      if (poses == null) {
        if (_pipeline != null) _framesDropped += 1;
        return;
      }
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
    if (degrees != null &&
        pose != null &&
        chainLandmarksObserved(JointChain.leg, observed)) {
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
    RepPipeline pipeline,
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
      timestampMs: _sessionClock?.elapsedMilliseconds ?? 0,
      imageWidth: rotated?.width,
      imageHeight: rotated?.height,
    );
    _traceRecorder?.record(landmarkFrame);

    // --- Coordinate-space diagnostic: log the FIRST calibration frame's
    // raw ML Kit values so we can see exactly what position3D.x/y look
    // like on this device.  Temporary — remove before shipping.
    if (!_calibDiagLogged && pipeline.calibrating && pose != null) {
      _calibDiagLogged = true;
      final ls = pose.landmarks[PoseLandmarkType.leftShoulder];
      final rs = pose.landmarks[PoseLandmarkType.rightShoulder];
      final lh = pose.landmarks[PoseLandmarkType.leftHip];
      final rh = pose.landmarks[PoseLandmarkType.rightHip];
      debugPrint('[CoordSpace] image: ${image.width}x${image.height}, '
          'degrees=$degrees, '
          'rotated: ${rotated?.width}x${rotated?.height}');
      debugPrint('[CoordSpace] leftShoulder: '
          'x=${ls?.x}, y=${ls?.y}, z=${ls?.z}, '
          'likelihood=${ls?.likelihood}');
      debugPrint('[CoordSpace] rightShoulder: '
          'x=${rs?.x}, y=${rs?.y}, z=${rs?.z}, '
          'likelihood=${rs?.likelihood}');
      debugPrint('[CoordSpace] leftHip: '
          'x=${lh?.x}, y=${lh?.y}, z=${lh?.z}, '
          'likelihood=${lh?.likelihood}');
      debugPrint('[CoordSpace] rightHip: '
          'x=${rh?.x}, y=${rh?.y}, z=${rh?.z}, '
          'likelihood=${rh?.likelihood}');
      if (ls != null && lh != null) {
        final dx = (ls.x - lh.x);
        final dy = (ls.y - lh.y);
        final w = rotated?.width ?? 0;
        final h = rotated?.height ?? 0;
        debugPrint('[CoordSpace] torso raw: dx=$dx, dy=$dy');
        debugPrint('[CoordSpace] torso _pointDistancePx calc: '
            '(dx*$w)^2 + (dy*$h)^2 = '
            '${(dx * w).toStringAsFixed(2)}^2 + '
            '${(dy * h).toStringAsFixed(2)}^2');
      }
    }

    final result = pipeline.tick(landmarkFrame);
    _diagRecorder?.recordTick(frame: landmarkFrame, result: result);
    pipelineFrames.value = result;
    // Retain every emitted rep for Evidence assembly — the one-frame
    // `justEmitted` pulse would otherwise be overwritten on the next
    // tick and lost. Append-only; EvidenceBuilder reads the snapshot.
    final emitted = result.justEmitted;
    if (emitted != null) _repEvents.add(emitted);
    // Set-level frame counter — Evidence's framesTotal. Every
    // successful inference during an active session counts.
    _framesTotal += 1;
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
        activeSideLandmarks: _activeSideLandmarks(
          result.selectedSide!,
          pipeline.config.chain,
        ),
      );
    }
    applyPose(drawable: drawable);
  }

  /// The chain landmarks of the counted side, for overlay colouring.
  Set<PoseLandmarkType> _activeSideLandmarks(
    String side,
    JointChain chain,
  ) => {
        poseLandmarkByName['$side${chain.proximal}']!,
        poseLandmarkByName['$side${chain.vertex}']!,
        poseLandmarkByName['$side${chain.distal}']!,
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

  /// Human-readable diagnostic snapshot from the most recent
  /// [finishSet] call. Displayed in the UI when Evidence assembly fails
  /// so the exact failing condition is visible on the phone. Temporary
  /// instrumentation — remove before shipping.
  String lastFinishDiagnostic = '';

  /// Finishes the current set: freezes the monotonic clock, snapshots
  /// the retained reps, capture metrics and calibration, then assembles
  /// an Evidence map through [EvidenceBuilder].
  ///
  /// Returns null when the session is not active, calibration was never
  /// accepted, or the builder refused (missing/invalid pixel scale refs,
  /// overlapping reps, etc.). The caller decides what to show the user.
  ///
  /// The clock is stopped here — subsequent frames still arrive but
  /// produce frozen timestamps (the `elapsedMilliseconds` after `stop()`
  /// is the final value). The caller should then submit through
  /// [ActiveSessionController.submit] and finally call [stopSession]
  /// (or navigate away, letting `dispose` clean up).
  Map<String, Object?>? finishSet({
    required SessionStart session,
    required SessionLocation location,
  }) {
    final clock = _sessionClock;
    final pipeline = _pipeline;
    if (clock == null || pipeline == null) {
      lastFinishDiagnostic = 'ABORT: clock=${clock != null}, '
          'pipeline=${pipeline != null}';
      debugPrint('[Evidence-Diag] $lastFinishDiagnostic');
      return null;
    }
    clock.stop();
    final setEndMs = clock.elapsedMilliseconds;
    final calibration = pipeline.calibration;
    final fpsMean = setEndMs > 0
        ? _framesTotal * 1000 / setEndMs
        : 0.0;
    final diag = StringBuffer()
      ..writeln('calibrating: ${pipeline.calibrating}')
      ..writeln('calibration: ${calibration != null ? "present" : "NULL"}')
      ..writeln('setEndMs: $setEndMs')
      ..writeln('repEvents: ${_repEvents.length}')
      ..writeln('framesTotal: $_framesTotal')
      ..writeln('framesDropped: $_framesDropped')
      ..writeln('fpsMean: ${fpsMean.toStringAsFixed(1)}')
      ..writeln('angle samples: ${pipeline.calibrationSampleCount}')
      ..writeln('torso samples: ${pipeline.calibrationTorsoSampleCount}')
      ..writeln('shoulder samples: ${pipeline.calibrationShoulderSampleCount}');
    if (calibration != null) {
      diag
        ..writeln('restSignal: ${calibration.restSignal}')
        ..writeln('torsoLengthPx: ${calibration.torsoLengthPx}')
        ..writeln('shoulderWidthPx: ${calibration.shoulderWidthPx}');
    }
    debugPrint('[Evidence-Diag]\n$diag');
    if (calibration == null) {
      lastFinishDiagnostic = '$diag\nFAIL: calibration is null';
      return null;
    }

    final evidence = EvidenceBuilder.build(
      context: EvidenceSessionContext(
        sessionId: session.sessionId,
        movementConfigVersion: session.movementConfigVersion,
        spotId: session.spotId,
        lat: location.lat,
        lng: location.lng,
        accuracyM: location.accuracyM,
        isMocked: location.isMocked,
      ),
      movementId: pipeline.config.id,
      measurementType: 'repBodyweight',
      startedAtMs: 0,
      endedAtMs: setEndMs,
      calibration: calibration,
      reps: List<RepEvent>.unmodifiable(_repEvents),
      framesTotal: _framesTotal,
      framesDropped: _framesDropped,
      fpsMean: fpsMean,
    );
    if (evidence == null) {
      // Pinpoint which builder check failed.
      final torsoPx = calibration.torsoLengthPx;
      final shoulderPx = calibration.shoulderWidthPx;
      final reason = StringBuffer('EvidenceBuilder REJECTED:');
      if (torsoPx == null) reason.write(' torsoLengthPx=NULL');
      if (shoulderPx == null) reason.write(' shoulderWidthPx=NULL');
      if (torsoPx != null && (torsoPx < 1 || torsoPx > 100000 || !torsoPx.isFinite)) {
        reason.write(' torsoLengthPx INVALID=$torsoPx');
      }
      if (shoulderPx != null && (shoulderPx < 1 || shoulderPx > 100000 || !shoulderPx.isFinite)) {
        reason.write(' shoulderWidthPx INVALID=$shoulderPx');
      }
      if (setEndMs <= 0) reason.write(' setEndMs<=0');
      for (var i = 0; i < _repEvents.length; i++) {
        final r = _repEvents[i];
        if (r.tStartMs < 0) reason.write(' rep[$i].tStartMs<0');
        if (r.tEndMs > setEndMs) reason.write(' rep[$i].tEndMs>setEndMs');
        if (r.tEndMs <= r.tStartMs) reason.write(' rep[$i].tEnd<=tStart');
      }
      lastFinishDiagnostic = '$diag\n$reason';
      debugPrint('[Evidence-Diag] $reason');
    } else {
      lastFinishDiagnostic = '$diag\nEvidenceBuilder: OK';
      debugPrint('[Evidence-Diag] EvidenceBuilder.build => OK');
    }
    return evidence;
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
