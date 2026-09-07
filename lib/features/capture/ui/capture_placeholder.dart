/// Capture placeholder — Track A owns the real capture flow (roles.md A-3
/// through A-19): camera → `InputImage` → pose landmarks → rep state machine
/// → Evidence. Nothing in this foundation touches ML Kit or the camera yet.
///
/// Ownership: A.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class CapturePlaceholder extends StatelessWidget {
  const CapturePlaceholder({
    super.key,
    this.onStartWorkout,
    this.isStarting = false,
    this.statusMessage,
    this.selectedMovementName,
  });

  final VoidCallback? onStartWorkout;
  final bool isStarting;
  final String? statusMessage;
  final String? selectedMovementName;

  @override
  Widget build(BuildContext context) {
    final movement = (selectedMovementName ?? 'squat').replaceAll('_', ' ');
    final movementTitle = '${movement[0].toUpperCase()}${movement.substring(1)}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.videocam_outlined),
                const SizedBox(width: RepRushTokens.spaceSm),
                Text(
                  'Camera counter',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: RepRushTokens.spaceXs),
            const Text(
              'Slice 1 counts squats on-device — no frame ever leaves the '
              'device (B2). Capture lands with Track A; this placeholder is '
              'the entry point C hands A.',
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            Wrap(
              spacing: RepRushTokens.spaceSm,
              children: [
                for (final state in LiveFeedbackState.values)
                  Chip(
                    avatar: Icon(state.icon, size: 18),
                    label: Text(state.cue),
                  ),
              ],
            ),
            if (isStarting) ...[
              const SizedBox(height: RepRushTokens.spaceMd),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: RepRushTokens.spaceSm),
                  Text(
                    statusMessage ?? 'Acquiring GPS fix & starting session...',
                    style: RepRushTokens.bodyLabel,
                  ),
                ],
              ),
            ] else if (onStartWorkout != null) ...[
              const SizedBox(height: RepRushTokens.spaceMd),
              BrandButton(
                icon: Icons.videocam,
                label: 'Start $movementTitle & Open Camera',
                onPressed: onStartWorkout,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
