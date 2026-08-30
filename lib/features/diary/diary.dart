/// Diary feature placeholder (v2 — requirements.md B13).
///
/// A diary entry is **not Evidence**. It is a future, non-competitive log of
/// workouts the camera can't verify — private history and personal-PR context
/// only. It never grants score, XP, territory power, mission progress,
/// unlocks, or leaderboard standing, and nothing here connects to the
/// session/ledger path.
///
/// Ownership: undecided until v2 — parked under C's surface scope for now.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class DiaryPlaceholder extends StatelessWidget {
  const DiaryPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Diary — coming in v2',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: RepRushTokens.spaceXs),
            const Text(
              'Log movements the camera can\'t verify: exercise, sets, reps, '
              'optional weight or duration, notes. Private history only — a '
              'diary entry never scores and never touches territory.',
            ),
          ],
        ),
      ),
    );
  }
}
