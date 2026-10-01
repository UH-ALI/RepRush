import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

/// XP per level — must match `XP_PER_LEVEL` in
/// `supabase/functions/_shared/stubs/consequences.ts`, the server's placeholder
/// curve, or the bar fills on a different cycle from the level number above it.
const int xpPerLevel = 250;

class XpBar extends StatelessWidget {
  const XpBar({super.key, required this.xp, required this.level});
  final int xp;
  final int level;

  @override
  Widget build(BuildContext context) {
    final intoLevel = xp % xpPerLevel;
    final progress = intoLevel / xpPerLevel;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'LEVEL $level',
              style: RepRushTokens.bodyLabel.copyWith(
                color: RepRushTokens.brand,
              ),
            ),
            const SizedBox(width: RepRushTokens.spaceSm),
            Flexible(
              child: Text(
                '${xpPerLevel - intoLevel} XP to level ${level + 1}',
                style: RepRushTokens.bodyLabel,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: progress),
          duration: RepRushTokens.slow,
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: SizedBox(
              height: 10,
              child: Stack(
                children: [
                  const ColoredBox(color: Colors.white12),
                  FractionallySizedBox(
                    widthFactor: value,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RepRushTokens.brandGradient,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
