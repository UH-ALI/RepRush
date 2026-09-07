import 'package:flutter/material.dart';

class TierBadge extends StatelessWidget {
  const TierBadge({super.key, required this.tier, this.locked = false});

  final int tier;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = [Colors.brown, Colors.blueGrey, Colors.amber, Colors.white];
    final color = locked ? Colors.white38 : colors[(tier - 1).clamp(0, 3)];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: .6)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text('T$tier', style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
      ),
    );
  }
}
