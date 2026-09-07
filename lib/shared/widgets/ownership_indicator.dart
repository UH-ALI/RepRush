import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class OwnershipIndicator extends StatelessWidget {
  const OwnershipIndicator({super.key, required this.ownership});
  final Ownership ownership;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(ownership.icon, color: ownership.color, size: 17),
    label: Text(ownership.label),
    side: BorderSide(color: ownership.color.withValues(alpha: .5)),
    backgroundColor: ownership.color.withValues(alpha: .12),
  );
}
