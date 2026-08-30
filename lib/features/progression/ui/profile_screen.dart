/// Profile screen — `GET /me` plus the variation tree state (`GET /movements`)
/// (requirements.md A2, C-7 placeholder).
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/diary/diary.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/shared/states/states.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final movements = ref.watch(movementsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        children: [
          profile.when(
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(profileProvider),
            ),
            data: (me) => Card(
              child: Padding(
                padding: const EdgeInsets.all(RepRushTokens.spaceMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      me.handle,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: RepRushTokens.spaceSm),
                    Text('Level ${me.level} · ${me.xp} XP'),
                    Text(
                      'Lifetime RepScore: '
                      '${me.lifetimeRepScore.toStringAsFixed(0)}',
                    ),
                    Text('Home spot: ${me.homeSpotId ?? '—'}'),
                    Text('Unlocked tiers: ${me.unlockedTiers.join(', ')}'),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: RepRushTokens.spaceLg),
          Text(
            'Variation tree',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          movements.when(
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(movementsProvider),
            ),
            data: (list) => Card(
              child: Column(
                children: [
                  for (final movement in list)
                    ListTile(
                      leading: Icon(
                        movement.unlocked
                            ? Icons.lock_open
                            : Icons.lock_outline,
                      ),
                      title: Text(movement.id.replaceAll('_', ' ')),
                      subtitle: Text(
                        '${movement.family.wireName} family · T${movement.tier}'
                        ' · ×${movement.difficulty.toStringAsFixed(1)}'
                        ' · ${movement.measurementType.wireName}',
                      ),
                      trailing: movement.repsTowardNextTier > 0
                          ? Text('${movement.repsTowardNextTier}/50')
                          : null,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: RepRushTokens.spaceLg),
          const DiaryPlaceholder(),
        ],
      ),
    );
  }
}
