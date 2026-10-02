/// Shared training-context widgets: which hex you are in, and the camera
/// privacy promise. Used by the map's train card and the Train tab.
///
/// Ownership: C.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/models/models.dart';

/// How close you are to taking a hex: your power in it, the power that takes
/// it, and about how many more reps of your chosen exercise that is.
typedef CaptureProgress = ({
  double yourPower,
  double target,
  int repsLeft,
  String exercise,
});

/// One line describing the hex the athlete is in — who holds it and what a
/// set here would do. With [progress], a hex you do not hold also shows how
/// far you are from taking it.
class HexStatusLine extends StatelessWidget {
  const HexStatusLine({super.key, required this.cell, this.progress});

  final HexCell? cell;
  final CaptureProgress? progress;

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
    final progress = ownership == Ownership.yours ? null : this.progress;
    final (title, body) = switch (ownership) {
      Ownership.yours => (
        "You're in your hex",
        '$power power. Train here to keep it strong.',
      ),
      Ownership.rival => (
        "You're in ${cell.ownerHandle}'s hex",
        progress == null
            ? '$power power. Out-train them to take it.'
            : 'About ${progress.repsLeft} more ${progress.exercise} '
                  'takes it.',
      ),
      Ownership.unclaimed => (
        "You're in an unclaimed hex",
        progress == null
            ? 'One solid set here claims it.'
            : 'One set of about ${progress.repsLeft} ${progress.exercise} '
                  'claims it.',
      ),
    };
    final row = Row(
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
    if (progress == null) return row;
    final share = progress.target <= 0
        ? 1.0
        : (progress.yourPower / progress.target).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        const SizedBox(height: RepRushTokens.spaceSm),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: share,
            minHeight: 8,
            color: RepRushTokens.brand,
            backgroundColor: Colors.white12,
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              'Your power ${progress.yourPower.round()}',
              style: RepRushTokens.bodyLabel.copyWith(fontSize: 12),
            ),
            const Spacer(),
            Text(
              ownership == Ownership.rival
                  ? '${progress.target.round()} to beat'
                  : '${progress.target.round()} to claim',
              style: RepRushTokens.bodyLabel.copyWith(fontSize: 12),
            ),
          ],
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
