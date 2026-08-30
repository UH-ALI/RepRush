/// Capture placeholder — Track A owns the real capture flow (roles.md A-3
/// through A-19): camera → `InputImage` → pose landmarks → rep state machine
/// → Evidence. Nothing in this foundation touches ML Kit or the camera yet.
///
/// Ownership: A.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class CapturePlaceholder extends StatelessWidget {
  const CapturePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
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
          ],
        ),
      ),
    );
  }
}
