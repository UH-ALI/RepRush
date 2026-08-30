/// Challenges screen — the Slice 1 static seeded daily challenge plus the
/// explicit claim step (G1, G3). Missions may award capped XP only.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/challenges/data/challenges_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';

class ChallengesScreen extends ConsumerWidget {
  const ChallengesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final challenge = ref.watch(dailyChallengeProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Challenges')),
      body: challenge.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(dailyChallengeProvider),
        ),
        data: (daily) => ListView(
          padding: const EdgeInsets.all(RepRushTokens.spaceMd),
          children: [_DailyChallengeCard(challenge: daily)],
        ),
      ),
    );
  }
}

class _DailyChallengeCard extends ConsumerWidget {
  const _DailyChallengeCard({required this.challenge});

  final DailyChallenge challenge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = challenge.progress / challenge.target;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Daily challenge',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: RepRushTokens.spaceXs),
            Text(challenge.description),
            const SizedBox(height: RepRushTokens.spaceMd),
            LinearProgressIndicator(value: progress.clamp(0.0, 1.0)),
            const SizedBox(height: RepRushTokens.spaceXs),
            Text('${challenge.progress}/${challenge.target} verified reps'),
            const SizedBox(height: RepRushTokens.spaceMd),
            FilledButton(
              onPressed: challenge.claimed ? null : () => _claim(context, ref),
              child: Text(challenge.claimed ? 'Claimed' : 'Claim reward'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _claim(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final claim = await ref.read(dailyChallengeProvider.notifier).claim();
      messenger.showSnackBar(
        SnackBar(content: Text('Claimed +${claim.xpAwarded} XP (capped)')),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
