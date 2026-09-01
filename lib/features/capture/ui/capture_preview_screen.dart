/// Capture preview — the single entry point A hands C (roles.md Seam 3):
/// rear-camera preview, ML Kit skeleton overlay, processing FPS, the
/// tracking-lost state, and the squat-counting HUD (calibration progress,
/// rep count, coaching cues).
///
/// Ownership: A.
library;

import 'dart:async' show Timer, unawaited;
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/data/capture_controller.dart';
import 'package:reprush/features/capture/data/capture_providers.dart';
import 'package:reprush/features/capture/pipeline/feedback.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';
import 'package:reprush/features/capture/ui/debug_panel.dart';
import 'package:reprush/features/capture/ui/skeleton_overlay.dart';

class CapturePreviewScreen extends ConsumerStatefulWidget {
  const CapturePreviewScreen({super.key});

  @override
  ConsumerState<CapturePreviewScreen> createState() =>
      _CapturePreviewScreenState();
}

class _CapturePreviewScreenState extends ConsumerState<CapturePreviewScreen>
    with WidgetsBindingObserver {
  late final CaptureController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = ref.read(captureControllerProvider.notifier);
    // Starts after the first frame — Riverpod forbids provider changes
    // during widget life-cycles. The squat session starts with the camera.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller.startSession(squatConfig);
      unawaited(_controller.start());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The camera must be released when the app backgrounds and reopened on
    // return — leaving it bound across the lifecycle edge is what breaks
    // the preview (camera plugin lifecycle contract).
    switch (state) {
      case AppLifecycleState.inactive ||
          AppLifecycleState.hidden ||
          AppLifecycleState.paused ||
          AppLifecycleState.detached:
        unawaited(_controller.pause());
      case AppLifecycleState.resumed:
        unawaited(_controller.resume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.stop());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(captureControllerProvider);
    return ClipRRect(
      borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
      child: ColoredBox(
        color: Colors.black,
        child: switch (status.phase) {
          CapturePhase.streaming => _PreviewStack(status: status),
          CapturePhase.paused => const _MessageView(
            icon: Icons.pause_circle_outline,
            message: 'Camera paused — return to the app to resume.',
          ),
          CapturePhase.initializing => const Center(
            child: CircularProgressIndicator(),
          ),
          CapturePhase.denied ||
          CapturePhase.unavailable ||
          CapturePhase.failed => _ProblemView(status: status),
        },
      ),
    );
  }
}

/// Preview + overlay + FPS chip + the pipeline HUD (or the legacy
/// tracking-lost banner when no session is active).
///
/// The preview is rendered at its native portrait size and cover-fitted
/// into the box — the same centre-crop transform `imageToViewPoint` applies
/// to the landmarks, which is what keeps the skeleton on the body.
class _PreviewStack extends ConsumerWidget {
  const _PreviewStack({required this.status});

  final CaptureStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final camera = ref
        .read(captureControllerProvider.notifier)
        .cameraController;
    if (camera == null || !camera.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    // previewSize is sensor-landscape; portrait display swaps the sides.
    final raw = camera.value.previewSize ?? const Size(1280, 720);
    final portrait = Size(
      math.min(raw.width, raw.height).toDouble(),
      math.max(raw.width, raw.height).toDouble(),
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: portrait.width,
            height: portrait.height,
            child: CameraPreview(camera),
          ),
        ),
        ValueListenableBuilder<PoseFrame?>(
          valueListenable: ref.watch(poseFramesProvider),
          builder: (context, frame, _) =>
              CustomPaint(painter: SkeletonOverlay(frame: frame)),
        ),
        Positioned(
          top: RepRushTokens.spaceSm,
          left: RepRushTokens.spaceSm,
          child: Chip(
            avatar: const Icon(Icons.speed, size: 18),
            label: Text('${status.fps} fps'),
          ),
        ),
        if (kDebugMode)
          const Positioned(
            top: RepRushTokens.spaceSm,
            right: RepRushTokens.spaceSm,
            child: CaptureDebugPanel(),
          ),
        ValueListenableBuilder<PipelineFrame?>(
          valueListenable: ref.watch(pipelineFramesProvider),
          builder: (context, pipelineFrame, _) {
            // While a session runs, the pipeline's red cue subsumes the
            // legacy tracking-lost banner.
            if (pipelineFrame != null) {
              return Positioned.fill(child: _PipelineHud(frame: pipelineFrame));
            }
            if (!status.trackingLost) return const SizedBox.shrink();
            return Positioned(
              left: RepRushTokens.spaceMd,
              right: RepRushTokens.spaceMd,
              bottom: RepRushTokens.spaceMd,
              child: _Banner(
                color: RepRushTokens.feedbackRed,
                icon: LiveFeedbackState.red.icon,
                text:
                    '${LiveFeedbackState.red.cue} — stand where the camera '
                    'can see your hips, knees, and ankles.',
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The counting-session HUD: calibration progress, the "Ready — go!"
/// hand-off, the rep counter, and the coaching cue banner. Cue text is
/// held for a minimum of [_minCueHold] to prevent flicker — complementing
/// the pipeline's own 3-frame debounce.
class _PipelineHud extends StatefulWidget {
  const _PipelineHud({required this.frame});

  final PipelineFrame frame;

  @override
  State<_PipelineHud> createState() => _PipelineHudState();
}

class _PipelineHudState extends State<_PipelineHud> {
  static const Duration _minCueHold = Duration(milliseconds: 500);

  late FeedbackSnapshot _shownCue = widget.frame.feedback;
  DateTime _shownAt = DateTime.fromMillisecondsSinceEpoch(0);
  late bool _wasCalibrating = widget.frame.calibrating;
  bool _showReadyGo = false;
  Timer? _readyTimer;

  @override
  void didUpdateWidget(_PipelineHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    final frame = widget.frame;
    if (_wasCalibrating && !frame.calibrating) {
      // Calibration just finalized — announce the start of counting.
      _readyTimer?.cancel();
      setState(() => _showReadyGo = true);
      _readyTimer = Timer(_minCueHold, () {
        if (mounted) setState(() => _showReadyGo = false);
      });
    }
    _wasCalibrating = frame.calibrating;

    final proposed = frame.feedback;
    final now = DateTime.now();
    if (proposed.cue != _shownCue.cue &&
        now.difference(_shownAt) >= _minCueHold) {
      setState(() {
        _shownCue = proposed;
        _shownAt = now;
      });
    }
  }

  @override
  void dispose() {
    _readyTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = widget.frame;
    final bannerColor = switch (_shownCue.level) {
      FeedbackLevel.green => RepRushTokens.brand,
      FeedbackLevel.amber => RepRushTokens.feedbackAmber,
      FeedbackLevel.red => RepRushTokens.feedbackRed,
    };
    final bannerIcon = switch (_shownCue.level) {
      FeedbackLevel.green => LiveFeedbackState.green.icon,
      FeedbackLevel.amber => LiveFeedbackState.amber.icon,
      FeedbackLevel.red => LiveFeedbackState.red.icon,
    };
    return Stack(
      fit: StackFit.expand,
      children: [
        if (frame.calibrating)
          // Minimal visible calibration state (§12a) — not the full
          // placement-card countdown, which is Track C/A-9/A-12.
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(
                horizontal: RepRushTokens.spaceLg,
              ),
              padding: const EdgeInsets.all(RepRushTokens.spaceMd),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Stand still — calibrating'),
                  const SizedBox(height: RepRushTokens.spaceXs),
                  // Placement guidance up front: most bad calibrations are
                  // an off-axis camera or bent knees, not a code bug.
                  const Text(
                    'Stand side-on, straighten legs, keep full body in frame',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(height: RepRushTokens.spaceSm),
                  if (frame.calibrationRejection case final reason?)
                    // A rejected attempt re-collects automatically — say
                    // why and what to fix (N9: icon + text + colour).
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.warning_amber,
                          size: 16,
                          color: RepRushTokens.feedbackAmber,
                        ),
                        const SizedBox(width: RepRushTokens.spaceXs),
                        Flexible(
                          child: Text(
                            calibrationRejectionMessage(reason),
                            style: const TextStyle(
                              fontSize: 12,
                              color: RepRushTokens.feedbackAmber,
                            ),
                          ),
                        ),
                      ],
                    )
                  else
                    LinearProgressIndicator(value: frame.calibrationProgress),
                ],
              ),
            ),
          )
        else if (_showReadyGo)
          const Center(
            child: Text(
              'Ready — go!',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
            ),
          )
        else ...[
          // Rep counter — bottom-right, only while counting.
          Positioned(
            right: RepRushTokens.spaceMd,
            bottom: RepRushTokens.spaceMd,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RepRushTokens.spaceMd,
                vertical: RepRushTokens.spaceSm,
              ),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.repeat),
                  const SizedBox(width: RepRushTokens.spaceSm),
                  Text(
                    '${frame.repCount}',
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Coaching cue banner — bottom-centre, N9 icon + text + colour.
          Positioned(
            left: RepRushTokens.spaceMd,
            right: RepRushTokens.spaceMd,
            bottom: 72,
            child: _Banner(
              color: bannerColor,
              icon: bannerIcon,
              text: _shownCue.cue,
            ),
          ),
        ],
      ],
    );
  }
}

/// A rounded status banner — icon + text + colour (N9: never colour alone).
class _Banner extends StatelessWidget {
  const _Banner({required this.color, required this.icon, required this.text});

  final Color color;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: RepRushTokens.spaceMd,
        vertical: RepRushTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
      ),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: RepRushTokens.spaceSm),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

/// Problem phases: icon + message + retry (N9 — colour is never the only
/// signal).
class _ProblemView extends ConsumerWidget {
  const _ProblemView({required this.status});

  final CaptureStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              status.phase == CapturePhase.denied
                  ? Icons.videocam_off
                  : Icons.videocam_outlined,
              size: 40,
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            Text(status.message, textAlign: TextAlign.center),
            const SizedBox(height: RepRushTokens.spaceMd),
            FilledButton.icon(
              onPressed: () =>
                  ref.read(captureControllerProvider.notifier).start(),
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageView extends StatelessWidget {
  const _MessageView({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [Icon(icon, size: 40), Text(message)],
        ),
      ),
    );
  }
}
