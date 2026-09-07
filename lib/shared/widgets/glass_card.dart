import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(RepRushTokens.spaceMd),
    this.glow = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final bool glow;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = AnimatedContainer(
      duration: RepRushTokens.medium,
      padding: padding,
      decoration: BoxDecoration(
        gradient: RepRushTokens.cardGradient,
        color: RepRushTokens.surfaceMid,
        borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
        border: Border.all(
          color: glow
              ? RepRushTokens.brand.withValues(alpha: .65)
              : RepRushTokens.brand.withValues(alpha: .14),
        ),
        boxShadow: glow ? RepRushTokens.brandGlow : RepRushTokens.cardShadow,
      ),
      child: child,
    );
    return onTap == null ? card : InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
      child: card,
    );
  }
}
