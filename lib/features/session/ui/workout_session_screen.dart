/// The full-screen workout: camera, rep counter and coaching cues, nothing
/// else. Pushed by [startTraining] once a session is open; replaced by the
/// summary when the set is scored.
///
/// Leaving mid-set (close button or system back) asks first and then abandons
/// the session — an open session left behind would only expire unscored.
///
/// Ownership: C (ui) — hosts A's [CapturePreviewScreen].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/ui/capture_preview_screen.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/session/ui/session_summary_screen.dart';
import 'package:reprush/features/session/ui/training_flow.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class WorkoutSessionScreen extends ConsumerStatefulWidget {
  const WorkoutSessionScreen({super.key, required this.movementId});

  final String movementId;

  @override
  ConsumerState<WorkoutSessionScreen> createState() =>
      _WorkoutSessionScreenState();
}

class _WorkoutSessionScreenState extends ConsumerState<WorkoutSessionScreen> {
  /// Set when the server has scored the set, so the session clearing (which
  /// submit does) is not mistaken for the session being dropped.
  bool _submitted = false;

  void _onSubmitted(SubmitResult result, int repCount) {
    _submitted = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => SessionSummaryScreen(
          result: result,
          repCount: repCount,
          movementId: widget.movementId,
        ),
      ),
    );
  }

  Future<void> _confirmLeave() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this set?'),
        content: const Text(
          "Reps from this set won't count, and it won't affect any territory.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End set'),
          ),
        ],
      ),
    );
    if (leave != true || !mounted) return;
    _submitted = true; // leaving on purpose; don't double-pop below
    ref.read(activeSessionProvider.notifier).abandon();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // The capture view drops a session the server has ended (expired, already
    // used…) and explains why in a snackbar; this screen then closes. Deferred
    // a frame because a SUCCESSFUL submit also clears the session, and its
    // summary hand-off lands in the same turn.
    ref.listen<SessionStart?>(activeSessionProvider, (_, next) {
      if (next != null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_submitted && mounted) Navigator.of(context).pop();
      });
    });

    final session = ref.watch(activeSessionProvider);
    final config = captureReadyConfigs[widget.movementId]!;
    final sessionHex = session == null
        ? null
        : ref
              .watch(hexesProvider)
              .value
              ?.where((c) => c.h3 == session.hexH3)
              .firstOrNull;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmLeave();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (session != null)
                CapturePreviewScreen(
                  key: ValueKey('${session.sessionId}/${widget.movementId}'),
                  config: config,
                  onSubmitted: _onSubmitted,
                ),
              Positioned(
                top: RepRushTokens.spaceSm,
                left: RepRushTokens.spaceSm,
                right: 64, // clear of the capture view's camera-switch button
                child: Row(
                  children: [
                    IconButton.filled(
                      tooltip: 'End set',
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black54,
                      ),
                      onPressed: _confirmLeave,
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: RepRushTokens.spaceSm),
                    Flexible(
                      child: _SessionTag(
                        movementId: widget.movementId,
                        hex: sessionHex,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Squat · rival_kat's hex" — what the set is and where it counts.
class _SessionTag extends StatelessWidget {
  const _SessionTag({required this.movementId, required this.hex});

  final String movementId;
  final HexCell? hex;

  @override
  Widget build(BuildContext context) {
    final hex = this.hex;
    final ownership = hex == null
        ? null
        : Ownership.fromWire(ownerHandle: hex.ownerHandle, yours: hex.yours);
    final where = switch (ownership) {
      Ownership.yours => 'your hex',
      Ownership.rival => "${hex!.ownerHandle}'s hex",
      Ownership.unclaimed => 'open hex',
      null => 'this hex',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              ownership?.icon ?? Icons.hexagon_outlined,
              size: 16,
              color: ownership?.color ?? Colors.white70,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '${movementDisplayName(movementId)} · $where',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
