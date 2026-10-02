/// Train tab — where you are, what you'll do, and one button to start (C1,
/// C2). The camera itself opens full-screen ([WorkoutSessionScreen]) through
/// [startTraining], the same path the map's "Train here" uses, so both entry
/// points share one location gate and one exercise list.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/ui/capture_placeholder.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/session/ui/training_flow.dart';
import 'package:reprush/features/spots/data/spots_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/features/territory/ui/current_hex_line.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class WorkoutScreen extends ConsumerStatefulWidget {
  const WorkoutScreen({super.key});

  @override
  ConsumerState<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends ConsumerState<WorkoutScreen> {
  bool _starting = false;

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await startTraining(context, ref);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final movements = ref.watch(movementsProvider);
    final selected = ref.watch(selectedMovementProvider);
    final current = ref.watch(currentHexProvider);
    final spots = ref.watch(nearbySpotsProvider);
    final inProgress = ref.watch(activeSessionProvider) != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Train')),
      body: ListView(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        children: [
          GlassCard(child: CurrentHexLine(cell: current)),
          const SizedBox(height: RepRushTokens.spaceLg),
          Text('Pick your exercise', style: RepRushTokens.sectionTitle),
          const SizedBox(height: RepRushTokens.spaceSm),
          movements.when(
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(movementsProvider),
            ),
            data: (list) => Column(
              children: [
                for (final movement in captureReadyMovements(list)) ...[
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
            ),
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          BrandButton(
            label: inProgress
                ? 'Return to your set'
                : 'Start ${movementPlural(selected)}',
            icon: Icons.play_arrow,
            loading: _starting,
            onPressed: _start,
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          const PrivacyLine(),
          const SizedBox(height: RepRushTokens.spaceLg),
          const CapturePlaceholder(),
          ...spots.maybeWhen(
            data: (list) => list.isEmpty
                ? const <Widget>[]
                : [
                    const SizedBox(height: RepRushTokens.spaceLg),
                    Text('Spots nearby', style: RepRushTokens.sectionTitle),
                    const SizedBox(height: RepRushTokens.spaceSm),
                    _SpotStrip(spots: list),
                  ],
            orElse: () => const <Widget>[],
          ),
        ],
      ),
    );
  }
}

class _SpotStrip extends StatelessWidget {
  const _SpotStrip({required this.spots});

  final List<SpotSummary> spots;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 86,
    child: ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: spots.length,
      separatorBuilder: (_, _) => const SizedBox(width: RepRushTokens.spaceSm),
      itemBuilder: (context, index) {
        final spot = spots[index];
        return GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.place, color: RepRushTokens.brand),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    spot.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    spot.verified
                        ? '${spot.distanceM?.round() ?? '?'} m · Verified'
                        : 'Unverified',
                    style: RepRushTokens.bodyLabel,
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
}
