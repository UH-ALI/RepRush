/// The hex you are standing in, with how close you are to taking it — your
/// power there against the holder's (or the claim floor), as a bar and as
/// "about N more squats". Shown on the map's train card and the Train tab.
///
/// Ownership: C (ui).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/ui/training_flow.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/async_current.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class CurrentHexLine extends ConsumerWidget {
  const CurrentHexLine({super.key, required this.cell});

  final HexCell? cell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cell = this.cell;
    if (cell == null || cell.yours) return HexStatusLine(cell: cell);

    // Your power here. A hex nobody has trained in has no record yet, which
    // is simply zero. `current`: never another mode's number.
    final yourPower = ref.watch(hexDetailProvider(cell.h3)).current?.yourPower;
    final unclaimed = cell.ownerHandle == null;
    final target = unclaimed ? claimFloorPower : cell.power;

    final movementId = ref.watch(selectedMovementProvider);
    final difficulty =
        ref
            .watch(movementsProvider)
            .value
            ?.where((m) => m.id == movementId)
            .firstOrNull
            ?.difficulty ??
        1.0;
    final perRep = difficulty * typicalFormFactor;
    // A rival's power has to be passed, not matched; and a set only counts
    // at all once it clears the claim floor.
    final gap = target - (yourPower ?? 0) + (unclaimed ? 0 : .1);
    final reps = math.max(
      (gap / perRep).ceil(),
      (claimFloorPower / perRep).ceil(),
    );

    return HexStatusLine(
      cell: cell,
      progress: (
        yourPower: yourPower ?? 0,
        target: target,
        repsLeft: reps,
        exercise: movementPlural(movementId),
      ),
    );
  }
}
