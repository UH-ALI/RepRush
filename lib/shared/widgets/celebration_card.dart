import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/shared/widgets/glass_card.dart';

class CelebrationCard extends StatelessWidget {
  const CelebrationCard({super.key, required this.title, required this.subtitle, this.icon = Icons.celebration});
  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) => GlassCard(
    glow: true,
    child: Row(children: [
      Icon(icon, color: RepRushTokens.brand, size: 32),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        Text(subtitle, style: RepRushTokens.bodyLabel),
      ])),
    ]),
  );
}
