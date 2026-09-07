import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class BrandButton extends StatelessWidget {
  const BrandButton({super.key, required this.label, required this.onPressed, this.icon, this.loading = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: onPressed == null ? const LinearGradient(colors: [Colors.white24, Colors.white12]) : RepRushTokens.brandGradient,
      borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
      boxShadow: onPressed == null ? null : RepRushTokens.brandGlow,
    ),
    child: SizedBox(
      height: 56,
      child: ElevatedButton.icon(
        onPressed: loading ? null : onPressed,
        icon: loading ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(icon ?? Icons.arrow_forward),
        label: Text(label),
        style: ElevatedButton.styleFrom(backgroundColor: Colors.transparent, shadowColor: Colors.transparent),
      ),
    ),
  );
}
