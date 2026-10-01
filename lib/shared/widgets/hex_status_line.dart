/// Shared training-context widgets: which hex you are in, and the camera
/// privacy promise. Used by the map's train card and the Train tab.
///
/// Ownership: C.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/models/models.dart';

/// One line describing the hex the athlete is in — who holds it and what a
/// set here would do.
class HexStatusLine extends StatelessWidget {
  const HexStatusLine({super.key, required this.cell});

  final HexCell? cell;

  @override
  Widget build(BuildContext context) {
    final cell = this.cell;
    if (cell == null) {
      return Row(
        children: [
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: RepRushTokens.spaceSm),
          Text('Finding your hex…', style: RepRushTokens.bodyLabel),
        ],
      );
    }
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
    final power = cell.power.round();
    final (title, body) = switch (ownership) {
      Ownership.yours => (
        "You're in your hex",
        '$power power. Train here to keep it strong.',
      ),
      Ownership.rival => (
        "You're in ${cell.ownerHandle}'s hex",
        '$power power. Out-train them to take it.',
      ),
      Ownership.unclaimed => (
        "You're in an unclaimed hex",
        'One solid set here claims it.',
      ),
    };
    return Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: ownership.color.withValues(alpha: .16),
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(ownership.icon, color: ownership.color),
          ),
        ),
        const SizedBox(width: RepRushTokens.spaceSm + 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(body, style: RepRushTokens.bodyLabel),
            ],
          ),
        ),
      ],
    );
  }
}

/// The privacy promise, stated where the camera is about to be used.
class PrivacyLine extends StatelessWidget {
  const PrivacyLine({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      const Icon(Icons.lock_outline, size: 14, color: Colors.white60),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          'Reps are counted on your phone. Video never leaves it.',
          style: RepRushTokens.bodyLabel.copyWith(fontSize: 12),
        ),
      ),
    ],
  );
}
