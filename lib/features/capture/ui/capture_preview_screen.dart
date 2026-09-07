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
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
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
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/models/models.dart';

class CapturePreviewScreen extends ConsumerStatefulWidget {
  const CapturePreviewScreen({super.key});

  @override
  ConsumerState<CapturePreviewScreen> createState() =>
      _CapturePreviewScreenState();
}

class _CapturePreviewScreenState extends ConsumerState<CapturePreviewScreen>
    with WidgetsBindingObserver {
  late final CaptureController _controller;

  /// True between the Finish press and the submit response arriving.
  /// The button is disabled while this is set so a double-tap cannot
  /// submit the same one-shot session twice.
  bool _submitting = false;

  /// Outcome of the last submit attempt — shown inline in the HUD for
  /// a few seconds. Null = no attempt yet, or the message was cleared.
  String? _submitMessage;
  bool _submitSucceeded = false;

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
    // If a set was finished and submitted, the controller's internal
    // state (pipeline, clock, rep list) can be safely torn down —
    // finishSet already captured the snapshot. If NOT finished, the
    // user navigated away mid-session; stop cleans up without losing
    // a pending submit (the one-shot session survives on the server
    // either way).
    unawaited(_controller.stop());
    super.dispose();
  }

  /// Finish → build Evidence → submit through the existing
  /// [ActiveSessionController.submit] path. The session is consumed on
  /// success and preserved on failure (so the user can retry).
  Future<void> _onFinishPressed() async {
    debugPrint('[Evidence-Diag] >>> _onFinishPressed called');
    if (_submitting) {
      debugPrint('[Evidence-Diag] >>> _onFinishPressed: already submitting, skip');
      return;
    }
    final session = ref.read(activeSessionProvider);
    final location =
        ref.read(activeSessionProvider.notifier).startLocation;
    debugPrint('[Evidence-Diag] >>> session=${session != null}, '
        'location=${location != null}');
    if (session == null || location == null) {
      setState(() {
        _submitMessage = 'Session expired — start a new one.';
        _submitSucceeded = false;
      });
      return;
    }
    setState(() => _submitting = true);
    debugPrint('[Evidence-Diag] >>> calling CaptureController.finishSet()');
    final evidence = _controller.finishSet(
      session: session,
      location: location,
    );
    debugPrint('[Evidence-Diag] >>> finishSet returned '
        '${evidence != null ? "OK" : "NULL"}');
    if (evidence == null) {
      final diag = _controller.lastFinishDiagnostic;
      setState(() {
        _submitting = false;
        _submitMessage = diag.isNotEmpty ? diag : 'Evidence incomplete.';
        _submitSucceeded = false;
      });
      return;
    }
    try {
      final result = await ref
          .read(activeSessionProvider.notifier)
          .submit(evidence);
      // Success: tear down the capture session. The one-shot is
      // consumed server-side.
      await _controller.stop();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitMessage =
            '+${result.xp} XP — ${result.achievements.join(", ")}';
        _submitSucceeded = true;
      });
    } on ApiException catch (e) {
      // Failure: the session is preserved for retry (server does
      // not consume on reject). Show the contract error.
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitMessage = '${e.code}: ${e.message}';
        _submitSucceeded = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(captureControllerProvider);
    return ClipRRect(
      borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
      child: ColoredBox(
        color: Colors.black,
        child: switch (status.phase) {
          CapturePhase.streaming => _PreviewStack(
            status: status,
            submitting: _submitting,
            submitMessage: _submitMessage,
            submitSucceeded: _submitSucceeded,
            onFinish: _onFinishPressed,
          ),
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
  const _PreviewStack({
    required this.status,
    required this.submitting,
    required this.onFinish,
    this.submitMessage,
    this.submitSucceeded = false,
  });

  final CaptureStatus status;
  final bool submitting;
  final String? submitMessage;
  final bool submitSucceeded;
  final VoidCallback onFinish;

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
              return Positioned.fill(
                child: _PipelineHud(
                  frame: pipelineFrame,
                  submitting: submitting,
                  submitMessage: submitMessage,
                  submitSucceeded: submitSucceeded,
                  onFinish: onFinish,
                ),
              );
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
  const _PipelineHud({
    required this.frame,
    required this.submitting,
    required this.onFinish,
    this.submitMessage,
    this.submitSucceeded = false,
  });

  final PipelineFrame frame;
  final bool submitting;
  final String? submitMessage;
  final bool submitSucceeded;
  final VoidCallback onFinish;

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

  /// Opens a centred, full-screen scrollable dialog showing the
  /// complete diagnostic text.  Temporary instrumentation — remove
  /// before shipping.
  void _showDiagnosticDialog(BuildContext context, String diagnostic) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: Padding(
          padding: const EdgeInsets.all(RepRushTokens.spaceMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Evidence Diagnostic',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: RepRushTokens.feedbackAmber,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const Divider(color: Colors.white24),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    diagnostic,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.5,
                      color: RepRushTokens.feedbackAmber,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
                    'Face the camera, straighten legs, keep full body in frame',
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
        else ...[          // Rep counter + Finish button — bottom-right, only while counting.
          Positioned(
            right: RepRushTokens.spaceMd,
            bottom: RepRushTokens.spaceMd,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: RepRushTokens.spaceMd,
                    vertical: RepRushTokens.spaceSm,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(
                      RepRushTokens.cornerChip,
                    ),
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
                const SizedBox(height: RepRushTokens.spaceSm),
                // Finish button — enabled only after calibration and
                // while no submit is in flight.
                FilledButton.icon(
                  onPressed: widget.submitting ? null : widget.onFinish,
                  icon: widget.submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check),
                  label: Text(
                    widget.submitting ? 'Submitting…' : 'Finish',
                  ),
                ),
                // Submit outcome / diagnostic — shown inline after a
                // press.  On failure the full diagnostic is tappable
                // and opens in a centred full-screen scrollable dialog.
                if (widget.submitMessage != null && widget.submitSucceeded)
                  Padding(
                    padding: const EdgeInsets.only(
                      top: RepRushTokens.spaceXs,
                    ),
                    child: Text(
                      widget.submitMessage!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: RepRushTokens.brand,
                      ),
                    ),
                  ),
                if (widget.submitMessage != null && !widget.submitSucceeded)
                  GestureDetector(
                    onTap: () => _showDiagnosticDialog(
                      context,
                      widget.submitMessage!,
                    ),
                    child: Container(
                      margin: const EdgeInsets.only(
                        top: RepRushTokens.spaceXs,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: RepRushTokens.spaceSm,
                        vertical: RepRushTokens.spaceXs,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: RepRushTokens.feedbackAmber,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Evidence incomplete — tap for diagnostic',
                            style: TextStyle(
                              fontSize: 11,
                              color: RepRushTokens.feedbackAmber,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
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
        color: color.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
        border: Border.all(color: Colors.white.withValues(alpha: .24)),
        boxShadow: [BoxShadow(color: color.withValues(alpha: .35), blurRadius: 14)],
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: RepRushTokens.spaceSm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
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
