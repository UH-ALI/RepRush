/// Post-set summary — the payoff of the loop: what the set earned, what it did
/// to the hex, and a way to go and see it on the map.
///
/// Every number here comes from the server's [SubmitResult] except [repCount],
/// which is the HUD's count and is shown as context, never as a score.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class SessionSummaryScreen extends StatelessWidget {
  const SessionSummaryScreen({
    super.key,
    required this.result,
    this.repCount,
    this.movementId,
    this.onShowOnMap,
    this.onContinue,
  });

  final SubmitResult result;

  /// Reps the HUD counted, for display.
  final int? repCount;
  final String? movementId;

  /// "See it on the map" — offered only when the set touched a hex.
  final void Function(String h3)? onShowOnMap;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final hex = result.hexResult;
    final title = hex == null
        ? 'Set complete'
        : hex.captured
        ? 'Hex captured!'
        : 'Power added';
    final setLine = [
      if (repCount != null) '$repCount reps',
      if (movementId != null) movementDisplayName(movementId!),
    ].join(' · ');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set complete'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        children: [
          GlassCard(
            glow: true,
            child: Column(
              children: [
                Icon(
                  hex?.captured == true ? Icons.flag : Icons.emoji_events,
                  color: RepRushTokens.brand,
                  size: 42,
                ),
                const SizedBox(height: RepRushTokens.spaceSm),
                Text(title, style: RepRushTokens.sectionTitle),
                const SizedBox(height: 4),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: result.xp.toDouble()),
                  duration: RepRushTokens.slow,
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => Text(
                    '+${value.round()} XP',
                    style: RepRushTokens.displayLarge,
                  ),
                ),
                if (setLine.isNotEmpty)
                  Text(setLine, style: RepRushTokens.bodyLabel),
              ],
            ),
          ),
          if (result.levelUps.isNotEmpty) ...[
            const SizedBox(height: RepRushTokens.spaceMd),
            CelebrationCard(
              title: 'Level up!',
              subtitle: "You're now level ${result.level}.",
              icon: Icons.keyboard_double_arrow_up,
            ),
          ],
          const SizedBox(height: RepRushTokens.spaceMd),
          _TerritoryCard(hex: hex),
          if (result.prs.isNotEmpty) ...[
            const SizedBox(height: RepRushTokens.spaceMd),
            for (final pr in result.prs)
              CelebrationCard(
                title: 'Personal record',
                subtitle:
                    '${movementDisplayName(pr.movementId)} · ${pr.metric}: '
                    '${pr.value}',
                icon: Icons.trending_up,
              ),
          ],
          for (final unlock in result.unlocks) ...[
            const SizedBox(height: RepRushTokens.spaceSm),
            CelebrationCard(
              title: 'Movement unlocked',
              subtitle: movementDisplayName(unlock),
              icon: Icons.lock_open,
            ),
          ],
          const SizedBox(height: RepRushTokens.spaceXl),
          if (hex != null && onShowOnMap != null) ...[
            BrandButton(
              label: 'See it on the map',
              icon: Icons.map,
              onPressed: () {
                Navigator.of(context).pop();
                onShowOnMap!(hex.h3);
              },
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            TextButton(
              onPressed: onContinue ?? () => Navigator.of(context).pop(),
              child: const Text('Keep training'),
            ),
          ] else
            BrandButton(
              label: 'Keep training',
              icon: Icons.arrow_forward,
              onPressed: onContinue ?? () => Navigator.of(context).pop(),
            ),
        ],
      ),
    );
  }
}

/// What the set did to the hex the session started in.
class _TerritoryCard extends StatelessWidget {
  const _TerritoryCard({required this.hex});

  final HexResult? hex;

  @override
  Widget build(BuildContext context) {
    final hex = this.hex;
    if (hex == null) {
      return const GlassCard(
        child: Row(
          children: [
            Icon(Icons.hexagon_outlined, color: Colors.white70),
            SizedBox(width: RepRushTokens.spaceSm),
            Expanded(
              child: Text(
                'No territory change this time. A longer set stakes a claim '
                'on the hex you are standing in.',
              ),
            ),
          ],
        ),
      );
    }

    final yours = hex.yourPower.round();
    final holder = hex.power.round();
    final ownership = hex.captured ? Ownership.yours : Ownership.rival;
    final share = hex.power <= 0
        ? 1.0
        : (hex.yourPower / hex.power).clamp(0.0, 1.0);
    final caption = hex.captured
        ? 'This hex is yours. Power fades over 72 hours, so come back to '
              'defend it.'
        : 'The holder still leads. ${(holder - yours + 1).clamp(1, holder)} '
              'more power takes it.';

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(ownership.icon, color: ownership.color),
              const SizedBox(width: RepRushTokens.spaceSm),
              Text(
                hex.captured ? 'You hold this hex' : 'Contested hex',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ],
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          Row(
            children: [
              Expanded(
                child: StatCard(
                  label: 'Your power',
                  value: '$yours',
                  icon: Icons.bolt,
                ),
              ),
              if (!hex.captured) ...[
                const SizedBox(width: RepRushTokens.spaceSm),
                Expanded(
                  child: StatCard(
                    label: 'Holder',
                    value: '$holder',
                    icon: Icons.shield,
                  ),
                ),
              ],
            ],
          ),
          if (!hex.captured) ...[
            const SizedBox(height: RepRushTokens.spaceSm),
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: share),
              duration: RepRushTokens.slow,
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 8,
                  color: Ownership.yours.color,
                  backgroundColor: Ownership.rival.color.withValues(alpha: .5),
                ),
              ),
            ),
          ],
          const SizedBox(height: RepRushTokens.spaceSm),
          Text(caption, style: RepRushTokens.bodyLabel),
        ],
      ),
    );
  }
}
