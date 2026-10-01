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
import 'package:reprush/shared/widgets/widgets.dart';

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
            data: (me) => GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: RepRushTokens.brand.withValues(alpha: .18),
                      child: const Icon(Icons.person, color: RepRushTokens.brand),
                    ),
                    const SizedBox(width: RepRushTokens.spaceSm),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(me.handle, style: RepRushTokens.sectionTitle),
                      Text('Level ${me.level} · ${me.xp} XP', style: RepRushTokens.bodyLabel),
                    ])),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(me.lifetimeRepScore.toStringAsFixed(0), style: RepRushTokens.statNumber),
                      Text('lifetime score', style: RepRushTokens.bodyLabel),
                    ]),
                  ]),
                  const SizedBox(height: RepRushTokens.spaceMd),
                  XpBar(xp: me.xp, level: me.level),
                  const SizedBox(height: RepRushTokens.spaceMd),
                  Row(children: [
                    if (me.homeSpotId case final spot?)
                      Expanded(child: Text('Home spot: $spot', style: RepRushTokens.bodyLabel))
                    else
                      const Spacer(),
                    Text('${me.unlockedTiers.length} movements unlocked', style: RepRushTokens.bodyLabel),
                  ]),
                ],
              ),
            ),
          ),
          const SizedBox(height: RepRushTokens.spaceLg),
          Text('Movement library', style: RepRushTokens.sectionTitle),
          const SizedBox(height: RepRushTokens.spaceSm),
          movements.when(
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(movementsProvider),
            ),
            data: (list) => GlassCard(
              child: Column(children: [
                  for (final movement in list)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: TierBadge(tier: movement.tier, locked: !movement.unlocked),
                      title: Text(movementDisplayName(movement.id), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${movement.difficulty.toStringAsFixed(1)}× points'
                          '${movement.repsTowardNextTier > 0 ? ' · ${movement.repsTowardNextTier} reps banked' : ''}'),
                      trailing: movement.unlocked ? const Icon(Icons.check_circle, color: RepRushTokens.brand) : const Icon(Icons.lock_outline),
                    ),
                ]),
            ),
          ),
          const SizedBox(height: RepRushTokens.spaceLg),
          const DiaryPlaceholder(),
        ],
      ),
    );
  }
}
