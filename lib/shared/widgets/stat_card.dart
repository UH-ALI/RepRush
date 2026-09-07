import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/shared/widgets/glass_card.dart';

class StatCard extends StatelessWidget {
  const StatCard({super.key, required this.label, required this.value, this.icon});
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => GlassCard(
    padding: const EdgeInsets.all(RepRushTokens.spaceSm),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (icon != null) Icon(icon, size: 18, color: RepRushTokens.brand),
      const SizedBox(height: 6),
      Text(value, style: RepRushTokens.statNumber),
      Text(label, style: RepRushTokens.bodyLabel),
    ]),
  );
}
