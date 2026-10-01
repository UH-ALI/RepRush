/// Compete tab — where you stand, today's challenge, and the territory
/// leaderboard (G1, G3, D7). Missions may award capped XP only; the board
/// ranks hexes held, which only verified sets can earn.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/challenges/data/challenges_providers.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/errors.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class ChallengesScreen extends ConsumerWidget {
  const ChallengesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final challenge = ref.watch(dailyChallengeProvider);
    final board = ref.watch(leaderboardProvider);
    final me = ref.watch(profileProvider).value?.handle;
    return Scaffold(
      appBar: AppBar(title: const Text('Compete')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref
            ..invalidate(dailyChallengeProvider)
            ..invalidate(leaderboardProvider);
          await ref.read(leaderboardProvider.future);
        },
        child: ListView(
          padding: const EdgeInsets.all(RepRushTokens.spaceMd),
          children: [
            ...board.maybeWhen(
              data: (rows) => [
                _StandingCard(rows: rows, me: me),
                const SizedBox(height: RepRushTokens.spaceMd),
              ],
              orElse: () => const <Widget>[],
            ),
            challenge.when(
              loading: () => const LoadingView(),
              error: (error, _) => ErrorView(
                error: error,
                onRetry: () => ref.invalidate(dailyChallengeProvider),
              ),
              data: (daily) => _DailyChallengeCard(challenge: daily),
            ),
            const SizedBox(height: RepRushTokens.spaceLg),
            Text('Territory leaderboard', style: RepRushTokens.sectionTitle),
            const SizedBox(height: RepRushTokens.spaceSm),
            board.when(
              loading: () => const LoadingView(),
              error: (error, _) => ErrorView(
                error: error,
                onRetry: () => ref.invalidate(leaderboardProvider),
              ),
              data: (rows) => rows.isEmpty
                  ? const GlassCard(
                      child: Text(
                        'Nobody holds territory yet. Claim the first hex and '
                        'top the board.',
                      ),
                    )
                  : GlassCard(
                      padding: const EdgeInsets.symmetric(
                        vertical: RepRushTokens.spaceSm,
                      ),
                      child: Column(
                        children: [
                          for (final row in rows)
                            _BoardRow(row: row, isMe: row.handle == me),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Your rank and territory at a glance.
class _StandingCard extends StatelessWidget {
  const _StandingCard({required this.rows, required this.me});

  final List<LeaderboardRow> rows;
  final String? me;

  @override
  Widget build(BuildContext context) {
    final mine = rows.where((r) => r.handle == me).firstOrNull;
    return Row(
      children: [
        Expanded(
          child: StatCard(
            label: 'Your rank',
            value: mine == null ? '—' : '#${mine.rank}',
            icon: Icons.leaderboard,
          ),
        ),
        const SizedBox(width: RepRushTokens.spaceSm),
        Expanded(
          child: StatCard(
            label: 'Hexes held',
            value: '${mine?.hexesHeld ?? 0}',
            icon: Icons.hexagon,
          ),
        ),
        const SizedBox(width: RepRushTokens.spaceSm),
        Expanded(
          child: StatCard(
            label: 'Territory',
            value: '${(mine?.areaKm2 ?? 0).toStringAsFixed(1)} km²',
            icon: Icons.map,
          ),
        ),
      ],
    );
  }
}

class _BoardRow extends StatelessWidget {
  const _BoardRow({required this.row, required this.isMe});

  final LeaderboardRow row;
  final bool isMe;

  static const _medals = [
    Color(0xFFFFC94D),
    Color(0xFFD0D6E2),
    Color(0xFFE09A5B),
  ];

  @override
  Widget build(BuildContext context) {
    final medal = row.rank <= 3 ? _medals[row.rank - 1] : null;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: RepRushTokens.spaceSm),
      padding: const EdgeInsets.symmetric(
        horizontal: RepRushTokens.spaceSm,
        vertical: 10,
      ),
      decoration: isMe
          ? BoxDecoration(
              color: RepRushTokens.brand.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
              border: Border.all(
                color: RepRushTokens.brand.withValues(alpha: .5),
              ),
            )
          : null,
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: medal != null
                ? Icon(Icons.workspace_premium, color: medal)
                : Text(
                    '${row.rank}',
                    textAlign: TextAlign.center,
                    style: RepRushTokens.sectionTitle.copyWith(fontSize: 18),
                  ),
          ),
          const SizedBox(width: RepRushTokens.spaceSm),
          Expanded(
            child: Text(
              isMe ? '${row.handle} (you)' : row.handle,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontWeight: isMe ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
          Text(
            '${row.hexesHeld}',
            style: RepRushTokens.sectionTitle.copyWith(fontSize: 20),
          ),
          const SizedBox(width: 4),
          Text(
            row.hexesHeld == 1 ? 'hex' : 'hexes',
            style: RepRushTokens.bodyLabel,
          ),
        ],
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
              Row(
                children: [
                  const Icon(Icons.bolt, color: RepRushTokens.brand),
                  const SizedBox(width: RepRushTokens.spaceSm),
                  Flexible(
                    child: Text(
                      'Daily challenge',
                      style: RepRushTokens.sectionTitle,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
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
                challenge.complete
                    ? '${challenge.progress}/${challenge.target} — complete!'
                    : '${challenge.progress}/${challenge.target} · '
                          '${challenge.target - challenge.progress} to go',
                style: RepRushTokens.bodyLabel,
              ),
              const SizedBox(height: RepRushTokens.spaceMd),
              // Claim opens only once the server-verified count reaches the
              // target; before that the button would only produce an error.
              BrandButton(
                onPressed: challenge.claimed || !challenge.complete
                    ? null
                    : () => _claim(context, ref),
                label: challenge.claimed
                    ? 'Claimed'
                    : challenge.complete
                    ? 'Claim reward'
                    : 'Keep training',
                icon: challenge.claimed
                    ? Icons.check
                    : challenge.complete
                    ? Icons.redeem
                    : Icons.lock_clock,
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
      // XP feeds the level shown on the profile.
      ref.invalidate(profileProvider);
      messenger.showSnackBar(
        SnackBar(content: Text('Reward claimed: +${claim.xpAwarded} XP')),
      );
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }
}
