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
import 'package:reprush/shared/widgets/widgets.dart';

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
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: RepRushTokens.slow,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - value)),
          child: child,
        ),
      ),
      child: GlassCard(
        glow: true,
        child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.bolt, color: RepRushTokens.brand),
              const SizedBox(width: RepRushTokens.spaceSm),
              Text('Daily challenge', style: RepRushTokens.sectionTitle),
            ]),
            const SizedBox(height: RepRushTokens.spaceXs),
            Text(challenge.description),
            const SizedBox(height: RepRushTokens.spaceMd),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
              duration: RepRushTokens.slow,
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 10,
                  color: RepRushTokens.brand,
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
            const SizedBox(height: RepRushTokens.spaceXs),
            Text(
              '${challenge.progress}/${challenge.target} verified reps',
              style: RepRushTokens.bodyLabel,
            ),
            const SizedBox(height: RepRushTokens.spaceMd),
            BrandButton(
              onPressed: challenge.claimed ? null : () => _claim(context, ref),
              label: challenge.claimed ? 'Claimed' : 'Claim reward',
              icon: challenge.claimed ? Icons.check : Icons.redeem,
            ),
          ],
        ),
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
