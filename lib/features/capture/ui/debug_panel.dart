/// Developer diagnostics panel (debug builds only) — live pipeline
/// measurements for tuning from evidence instead of guessing: angles,
/// frozen thresholds, side selection, per-side visibility, phase, counts,
/// and frame rate, plus Recalibrate and diagnostics-export actions.
///
/// Everything shown is local-only and never enters Evidence. The panel is
/// instantiated behind a `kDebugMode` gate in the preview stack, so it is
/// dead code in release builds.
///
/// Ownership: A.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/data/capture_providers.dart';
import 'package:reprush/features/capture/pipeline/feedback.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';

/// Collapsible diagnostics overlay. Collapsed = one small chip; expanded
/// = the full measurement grid + actions.
class CaptureDebugPanel extends ConsumerStatefulWidget {
  const CaptureDebugPanel({super.key});

  @override
  ConsumerState<CaptureDebugPanel> createState() => _CaptureDebugPanelState();
}

class _CaptureDebugPanelState extends ConsumerState<CaptureDebugPanel> {
  bool _expanded = false;
  String? _exportNote;

  @override
  Widget build(BuildContext context) {
    if (!_expanded) {
      return _chip(
        label: 'DIAG',
        onTap: () => setState(() => _expanded = true),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.all(RepRushTokens.spaceSm),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
      ),
      child: ValueListenableBuilder<PipelineFrame?>(
        valueListenable: ref.watch(pipelineFramesProvider),
        builder: (context, frame, _) {
          final fps = ref.watch(captureControllerProvider).fps;
          final cal = frame?.calibration;
          return DefaultTextStyle(
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 1.35,
              color: Colors.white,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Diagnostics',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    _miniIconButton(
                      icon: Icons.close,
                      onTap: () => setState(() => _expanded = false),
                    ),
                  ],
                ),
                Text(
                  'raw ${_fmt(frame?.rawAngle)}  smooth ${_fmt(frame?.smoothedAngle)}',
                ),
                Text(
                  'rest ${_fmt(cal?.restSignal)}\n'
                  'startDescent ${_fmt(cal?.startDescent)}  enterPeak ${_fmt(cal?.enterPeak)}\n'
                  'enterRest ${_fmt(cal?.enterRest)}  romTarget ${_fmt(cal?.romTarget)}',
                ),
                Text(
                  'side ${frame?.selectedSide ?? '-'}'
                  '${frame?.sideSwitched ?? false ? ' (switched)' : ''}',
                ),
                Text(
                  'vis L ${_fmt(frame?.leftVisibility)}  R ${_fmt(frame?.rightVisibility)}',
                ),
                Text(
                  'phase ${frame?.phase.name ?? '-'}'
                  '${frame?.calibrating ?? false ? ' (calibrating)' : ''}',
                ),
                Text(
                  'reps ${frame?.repCount ?? 0}  shallow ${frame?.shallowAttemptCount ?? 0}'
                  '  fps $fps',
                ),
                if (frame?.calibrationRejection case final reason?)
                  Padding(
                    padding: const EdgeInsets.only(top: RepRushTokens.spaceXs),
                    child: Text(
                      calibrationRejectionMessage(reason),
                      style: const TextStyle(
                        color: RepRushTokens.feedbackAmber,
                      ),
                    ),
                  ),
                if (_exportNote case final note?) Text(note),
                const SizedBox(height: RepRushTokens.spaceXs),
                Row(
                  children: [
                    _actionButton(
                      label: 'Recalibrate',
                      onTap: () => ref
                          .read(captureControllerProvider.notifier)
                          .recalibrate(),
                    ),
                    const SizedBox(width: RepRushTokens.spaceSm),
                    _actionButton(
                      label: 'Export',
                      onTap: () {
                        final count = ref
                            .read(captureControllerProvider.notifier)
                            .exportDiagnosticsToLog();
                        setState(() {
                          _exportNote = count > 0
                              ? 'exported $count entries to log'
                              : 'nothing to export';
                        });
                      },
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _fmt(double? value) =>
      value == null ? '-' : value.toStringAsFixed(1);

  Widget _chip({required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RepRushTokens.spaceSm,
          vertical: RepRushTokens.spaceXs,
        ),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bug_report, size: 14, color: Colors.white),
            SizedBox(width: RepRushTokens.spaceXs),
            Text(
              'DIAG',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceXs),
        child: Icon(icon, size: 14, color: Colors.white),
      ),
    );
  }

  Widget _actionButton({required String label, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: RepRushTokens.spaceSm,
          vertical: RepRushTokens.spaceXs,
        ),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white54),
          borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
        ),
        child: Text(label),
      ),
    );
  }
}
