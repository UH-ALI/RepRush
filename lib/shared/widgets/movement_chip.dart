import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/widgets/tier_badge.dart';

class MovementChip extends StatelessWidget {
  const MovementChip({
    super.key,
    required this.movement,
    required this.selected,
    required this.onTap,
  });

  final Movement movement;
  final bool selected;

  /// Null disables the chip (e.g. while a set is in progress); a disabled
  /// chip that is not the selected one is dimmed like a locked movement.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = movement.unlocked && onTap != null;
    return Opacity(
      opacity: enabled || selected ? 1 : .45,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: RepRushTokens.medium,
          curve: Curves.easeOutCubic,
          width: 142,
          padding: const EdgeInsets.all(RepRushTokens.spaceSm),
          decoration: BoxDecoration(
            gradient: selected
                ? RepRushTokens.brandGradient
                : RepRushTokens.surfaceGradient,
            borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
            border: Border.all(
              color: selected ? RepRushTokens.brand : Colors.white12,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: selected ? RepRushTokens.brandGlow : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    movementIcon(movement.family),
                    color: selected ? Colors.white : RepRushTokens.brand,
                  ),
                  if (!movement.unlocked) const Icon(Icons.lock, size: 16),
                ],
              ),
              const Spacer(),
              Text(
                movementDisplayName(movement.id),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TierBadge(tier: movement.tier, locked: !movement.unlocked),
                  Text(
                    '×${movement.difficulty.toStringAsFixed(1)}',
                    style: RepRushTokens.bodyLabel,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One icon per movement family, shared by every exercise picker.
IconData movementIcon(MovementFamily family) => switch (family) {
  MovementFamily.squat => Icons.accessibility_new,
  MovementFamily.push => Icons.sports_gymnastics,
  MovementFamily.pull => Icons.vertical_align_top,
  MovementFamily.hold => Icons.timer_outlined,
  MovementFamily.jump => Icons.north,
};

/// "push_up" → "Push-up", "archer_push_up" → "Archer push-up". The catalogue
/// ids are snake_case wire values; athletes read hyphenated names.
String movementDisplayName(String id) {
  final words = id
      .replaceAll('push_up', 'push-up')
      .replaceAll('pull_up', 'pull-up')
      .replaceAll('muscle_up', 'muscle-up')
      .replaceAll('chin_up', 'chin-up')
      .replaceAll('sit_up', 'sit-up')
      .replaceAll('_', ' ');
  return words.isEmpty ? words : words[0].toUpperCase() + words.substring(1);
}
