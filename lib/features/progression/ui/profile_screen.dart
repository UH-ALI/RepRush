/// Profile — `GET /me` plus the movement library (`GET /movements`) and your
/// standing from the territory board (requirements.md A2, C-7).
///
/// Ownership: C (ui).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(profileProvider);
    final movements = ref.watch(movementsProvider);
    final board = ref.watch(leaderboardProvider).value ?? const [];
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
            data: (me) {
              final standing = board
                  .where((r) => r.handle == me.handle)
                  .firstOrNull;
              return Column(
                children: [
                  GlassCard(
                    glow: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _LevelAvatar(profile: me),
                            const SizedBox(width: RepRushTokens.spaceMd),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    me.handle,
                                    style: RepRushTokens.sectionTitle,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    'Level ${me.level} · ${me.xp} XP',
                                    style: RepRushTokens.bodyLabel,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: RepRushTokens.spaceMd),
                        XpBar(xp: me.xp, level: me.level),
                      ],
                    ),
                  ),
                  const SizedBox(height: RepRushTokens.spaceSm),
                  Row(
                    children: [
                      Expanded(
                        child: StatCard(
                          label: 'lifetime score',
                          value: me.lifetimeRepScore.toStringAsFixed(0),
                          icon: Icons.bolt,
                        ),
                      ),
                      const SizedBox(width: RepRushTokens.spaceSm),
                      Expanded(
                        child: StatCard(
                          label: 'hexes held',
                          value: '${standing?.hexesHeld ?? 0}',
                          icon: Icons.hexagon,
                        ),
                      ),
                      const SizedBox(width: RepRushTokens.spaceSm),
                      Expanded(
                        child: StatCard(
                          label: 'rank',
                          value: standing == null ? '—' : '#${standing.rank}',
                          icon: Icons.leaderboard,
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
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
            data: (list) {
              final unlocked = list.where((m) => m.unlocked).toList();
              final locked = list.where((m) => !m.unlocked).toList();
              return GlassCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: RepRushTokens.spaceMd,
                  vertical: RepRushTokens.spaceSm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final movement in unlocked)
                      _MovementRow(movement: movement),
                    if (locked.isNotEmpty) ...[
                      const Divider(height: RepRushTokens.spaceLg),
                      Text(
                        'LOCKED — UNLOCK BY TRAINING',
                        style: RepRushTokens.bodyLabel.copyWith(
                          letterSpacing: 1.2,
                          color: Colors.white54,
                        ),
                      ),
                      for (final movement in locked)
                        _MovementRow(movement: movement),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// Initials inside a ring that fills as you approach the next level.
class _LevelAvatar extends StatelessWidget {
  const _LevelAvatar({required this.profile});

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final progress = (profile.xp % xpPerLevel) / xpPerLevel;
    final initials = profile.handle
        .replaceAll(RegExp('[^A-Za-z]'), '')
        .characters
        .take(2)
        .toString()
        .toUpperCase();
    return SizedBox.square(
      dimension: 72,
      child: Stack(
        alignment: Alignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: progress),
            duration: RepRushTokens.slow,
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => SizedBox.square(
              dimension: 72,
              child: CircularProgressIndicator(
                value: math.max(value, .02),
                strokeWidth: 5,
                color: RepRushTokens.brand,
                backgroundColor: Colors.white12,
              ),
            ),
          ),
          CircleAvatar(
            radius: 28,
            backgroundColor: RepRushTokens.surfaceRaised,
            child: Text(
              initials.isEmpty ? '?' : initials,
              style: RepRushTokens.sectionTitle.copyWith(
                color: RepRushTokens.brand,
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RepRushTokens.brandGradient,
                borderRadius: BorderRadius.circular(99),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                child: Text(
                  '${profile.level}',
                  style: const TextStyle(
                    fontFamily: RepRushTokens.displayFont,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.movement});

  final Movement movement;

  @override
  Widget build(BuildContext context) {
    final banked = movement.repsTowardNextTier;
    return Opacity(
      opacity: movement.unlocked ? 1 : .5,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              movementIcon(movement.family),
              color: movement.unlocked ? RepRushTokens.brand : Colors.white54,
            ),
            const SizedBox(width: RepRushTokens.spaceSm + 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    movementDisplayName(movement.id),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    '${movement.difficulty.toStringAsFixed(1)}× points'
                    '${banked > 0 ? ' · $banked reps banked' : ''}',
                    style: RepRushTokens.bodyLabel,
                  ),
                ],
              ),
            ),
            Icon(
              movement.unlocked ? Icons.check_circle : Icons.lock_outline,
              size: 20,
              color: movement.unlocked ? RepRushTokens.brand : Colors.white54,
            ),
          ],
        ),
      ),
    );
  }
}
