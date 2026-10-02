import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class BrandButton extends StatelessWidget {
  const BrandButton({super.key, required this.label, required this.onPressed, this.icon, this.loading = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: RepRushTokens.fast,
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
        // The container above paints the button; the Material button inside
        // must match its shape and stay transparent — including disabled,
        // where Material's default grey stadium would otherwise sit inside
        // the rounded rectangle with the corners showing around it.
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          disabledBackgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white60,
          disabledIconColor: Colors.white60,
          shadowColor: Colors.transparent,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    ),
  );
}
