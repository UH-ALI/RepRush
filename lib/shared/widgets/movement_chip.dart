import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/widgets/tier_badge.dart';

class MovementChip extends StatelessWidget {
  const MovementChip({super.key, required this.movement, required this.selected, required this.onTap});

  final Movement movement;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: movement.unlocked ? 1 : .45,
      child: GestureDetector(
        onTap: movement.unlocked ? onTap : null,
        child: AnimatedContainer(
          duration: RepRushTokens.medium,
          curve: Curves.easeOutCubic,
          width: 142,
          padding: const EdgeInsets.all(RepRushTokens.spaceSm),
          decoration: BoxDecoration(
            gradient: selected ? RepRushTokens.brandGradient : RepRushTokens.surfaceGradient,
            borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
            border: Border.all(color: selected ? RepRushTokens.brand : Colors.white12, width: selected ? 1.5 : 1),
            boxShadow: selected ? RepRushTokens.brandGlow : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Icon(_iconFor(movement.family), color: selected ? Colors.white : RepRushTokens.brand),
                if (!movement.unlocked) const Icon(Icons.lock, size: 16),
              ]),
              const Spacer(),
              Text(movement.id.replaceAll('_', ' '), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                TierBadge(tier: movement.tier, locked: !movement.unlocked),
                Text('×${movement.difficulty.toStringAsFixed(1)}', style: RepRushTokens.bodyLabel),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(MovementFamily family) => switch (family) {
    MovementFamily.squat => Icons.directions_run,
    MovementFamily.push => Icons.fitness_center,
    MovementFamily.pull => Icons.vertical_align_top,
    MovementFamily.hold => Icons.timer_outlined,
    MovementFamily.jump => Icons.north,
  };
}
