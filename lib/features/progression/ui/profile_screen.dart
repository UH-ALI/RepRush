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
                    Text(me.lifetimeRepScore.toStringAsFixed(0), style: RepRushTokens.statNumber),
                  ]),
                  const SizedBox(height: RepRushTokens.spaceMd),
                  XpBar(xp: me.xp, level: me.level),
                  const SizedBox(height: RepRushTokens.spaceMd),
                  Row(children: [
                    Expanded(child: Text('Home spot: ${me.homeSpotId ?? '—'}', style: RepRushTokens.bodyLabel)),
                    Text('${me.unlockedTiers.length} tiers unlocked', style: RepRushTokens.bodyLabel),
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
                      title: Text(movement.id.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('×${movement.difficulty.toStringAsFixed(1)} · ${movement.family.wireName}'),
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
