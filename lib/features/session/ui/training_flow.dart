/// The one path into a workout, shared by the map ("Train here") and the
/// Train tab: pick an exercise → open a session where you stand → full-screen
/// camera. Keeping it in one place is what keeps the two entry points
/// behaving identically — same location gate, same exercise list, same screen.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/session/ui/workout_session_screen.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/errors.dart';
import 'package:reprush/shared/widgets/widgets.dart';

/// Movements with a capture-ready pipeline config on the client, in the order
/// they are offered. Only these appear in any picker: a movement the camera
/// cannot count would be a dead end mid-workout. Add entries as new
/// MovementConfigs land in Track A.
const Map<String, MovementConfig> captureReadyConfigs = {
  'squat': squatConfig,
  'push_up': pushUpConfig,
  'pull_up': pullUpConfig,
};

/// The exercise the next set will use — shared so the map's picker and the
/// Train tab remember the same choice.
class SelectedMovementController extends Notifier<String> {
  @override
  String build() => captureReadyConfigs.keys.first;

  void select(String movementId) {
    if (captureReadyConfigs.containsKey(movementId)) state = movementId;
  }
}

final selectedMovementProvider =
    NotifierProvider<SelectedMovementController, String>(
      SelectedMovementController.new,
    );

/// The capture-ready movements from the catalogue, in [captureReadyConfigs]
/// order.
List<Movement> captureReadyMovements(List<Movement> catalogue) => [
  for (final id in captureReadyConfigs.keys)
    ...catalogue.where((m) => m.id == id),
];

/// Opens a session where the athlete is standing and pushes the full-screen
/// workout. [targetH3] is the hex the athlete chose on the map, if any — the
/// session is refused unless they are inside it. Failures surface as a
/// snackbar; the returned future completes when the workout screen closes.
Future<void> startTraining(
  BuildContext context,
  WidgetRef ref, {
  String? targetH3,
}) async {
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final movementId = ref.read(selectedMovementProvider);

  // A set already in progress: go back to it rather than opening another.
  if (ref.read(activeSessionProvider) == null) {
    try {
      await ref
          .read(activeSessionProvider.notifier)
          .startHere(targetH3: targetH3);
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
      return;
    }
  }
  await navigator.push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => WorkoutSessionScreen(movementId: movementId),
    ),
  );
}

/// Bottom sheet: choose an exercise, then start. Used by the map so training
/// is two taps from the hex you are standing in.
Future<void> showTrainSheet(
  BuildContext context, {
  required String title,
  required String subtitle,
  required Future<void> Function() onStart,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: RepRushTokens.surfaceDark,
    isScrollControlled: true,
    builder: (_) =>
        _TrainSheet(title: title, subtitle: subtitle, onStart: onStart),
  );
}

class _TrainSheet extends ConsumerWidget {
  const _TrainSheet({
    required this.title,
    required this.subtitle,
    required this.onStart,
  });

  final String title;
  final String subtitle;
  final Future<void> Function() onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final movements = ref.watch(movementsProvider);
    final selected = ref.watch(selectedMovementProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: RepRushTokens.sectionTitle),
            const SizedBox(height: RepRushTokens.spaceXs),
            Text(subtitle, style: RepRushTokens.bodyLabel),
            const SizedBox(height: RepRushTokens.spaceMd),
            ...switch (movements) {
              AsyncData(:final value) => [
                for (final movement in captureReadyMovements(value)) ...[
                  MovementTile(
                    movement: movement,
                    selected: movement.id == selected,
                    onTap: () => ref
                        .read(selectedMovementProvider.notifier)
                        .select(movement.id),
                  ),
                  const SizedBox(height: RepRushTokens.spaceSm),
                ],
              ],
              AsyncError(:final error) => [Text(describeError(error))],
              _ => const [
                Padding(
                  padding: EdgeInsets.all(RepRushTokens.spaceMd),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            },
            const SizedBox(height: RepRushTokens.spaceSm),
            BrandButton(
              label: 'Start ${movementPlural(selected)}',
              icon: Icons.play_arrow,
              onPressed: () async {
                Navigator.pop(context);
                await onStart();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// "squat" → "squats", "push_up" → "push-ups" — for button copy.
String movementPlural(String movementId) =>
    '${movementDisplayName(movementId).toLowerCase()}s';

/// A large, tappable exercise row — icon, name, multiplier, banked reps.
class MovementTile extends StatelessWidget {
  const MovementTile({
    super.key,
    required this.movement,
    required this.selected,
    required this.onTap,
  });

  final Movement movement;
  final bool selected;

  /// Null disables the tile (locked movement, or a set in progress).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = movement.unlocked && onTap != null;
    final banked = movement.repsTowardNextTier;
    return Opacity(
      opacity: enabled || selected ? 1 : .45,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: AnimatedContainer(
          duration: RepRushTokens.fast,
          padding: const EdgeInsets.all(RepRushTokens.spaceSm + 4),
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
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: selected ? .18 : .06),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(
                    movementIcon(movement.family),
                    color: selected ? Colors.white : RepRushTokens.brand,
                  ),
                ),
              ),
              const SizedBox(width: RepRushTokens.spaceSm + 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      movementDisplayName(movement.id),
                      style: RepRushTokens.sectionTitle.copyWith(fontSize: 20),
                    ),
                    Text(
                      '${movement.difficulty.toStringAsFixed(1)}× points'
                      '${banked > 0 ? ' · $banked reps banked' : ''}',
                      style: RepRushTokens.bodyLabel,
                    ),
                  ],
                ),
              ),
              Icon(
                !movement.unlocked
                    ? Icons.lock_outline
                    : selected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                color: selected ? Colors.white : Colors.white38,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
