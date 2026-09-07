import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class XpBar extends StatelessWidget {
  const XpBar({super.key, required this.xp, required this.level});
  final int xp;
  final int level;

  @override
  Widget build(BuildContext context) {
    final progress = (xp % 1000) / 1000;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('LEVEL $level', style: RepRushTokens.bodyLabel.copyWith(color: RepRushTokens.brand)),
        Text('$xp XP', style: RepRushTokens.bodyLabel),
      ]),
      const SizedBox(height: 8),
      TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: progress),
        duration: RepRushTokens.slow,
        curve: Curves.easeOutCubic,
        builder: (context, value, _) => ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: SizedBox(height: 10, child: Stack(children: [
          const ColoredBox(color: Colors.white12),
          FractionallySizedBox(widthFactor: value, child: const DecoratedBox(decoration: BoxDecoration(gradient: RepRushTokens.brandGradient))),
        ])),
        ),
      ),
    ]);
  }
}
