import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/widgets/widgets.dart';

/// Post-submit celebration surface. The capture feature can push this screen
/// with its existing [SubmitResult] without passing score data back upstream.
class SessionSummaryScreen extends StatelessWidget {
  const SessionSummaryScreen({
    super.key,
    required this.result,
    this.onContinue,
  });

  final SubmitResult result;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final hex = result.hexResult;
    return Scaffold(
      appBar: AppBar(title: const Text('Set complete')),
      body: ListView(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        children: [
          GlassCard(
            glow: true,
            child: Column(children: [
              const Icon(Icons.emoji_events, color: RepRushTokens.brand, size: 42),
              const SizedBox(height: RepRushTokens.spaceSm),
              Text(hex == null ? 'Great work' : 'Territory captured', style: RepRushTokens.sectionTitle),
              const SizedBox(height: 4),
              Text('+${result.xp} XP', style: RepRushTokens.displayLarge),
              Text('Level ${result.level}', style: RepRushTokens.bodyLabel),
            ]),
          ),
          const SizedBox(height: RepRushTokens.spaceMd),
          Row(children: [
            Expanded(child: StatCard(label: 'Power', value: hex?.power.toStringAsFixed(0) ?? '—', icon: Icons.bolt)),
            const SizedBox(width: RepRushTokens.spaceSm),
            Expanded(child: StatCard(label: 'Hex', value: hex?.h3.substring(0, hex.h3.length.clamp(0, 8)) ?? '—', icon: Icons.hexagon)),
          ]),
          if (hex != null) ...[
            const SizedBox(height: RepRushTokens.spaceMd),
            OwnershipIndicator(ownership: hex.captured ? Ownership.yours : Ownership.rival),
          ],
          if (result.prs.isNotEmpty) ...[
            const SizedBox(height: RepRushTokens.spaceMd),
            for (final pr in result.prs)
              CelebrationCard(
                title: 'Personal record',
                subtitle: '${pr.movementId} · ${pr.metric}: ${pr.value}',
                icon: Icons.trending_up,
              ),
          ],
          for (final unlock in result.unlocks) ...[
            const SizedBox(height: RepRushTokens.spaceSm),
            CelebrationCard(title: 'Movement unlocked', subtitle: unlock, icon: Icons.lock_open),
          ],
          const SizedBox(height: RepRushTokens.spaceXl),
          BrandButton(
            label: 'Continue',
            icon: Icons.arrow_forward,
            onPressed: onContinue ?? () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}
