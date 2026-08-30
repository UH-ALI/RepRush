/// Workout screen — session lifecycle, movement selection, and the capture
/// entry point (C1, C2). Seam 3 (roles.md §4): C owns how you get in —
/// movement picker and session context — and A owns the capture screen
/// itself.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/ui/capture_placeholder.dart';
import 'package:reprush/features/capture/ui/capture_preview_screen.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/spots/data/spots_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';

class WorkoutScreen extends ConsumerStatefulWidget {
  const WorkoutScreen({super.key});

  @override
  ConsumerState<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends ConsumerState<WorkoutScreen> {
  /// Slice 1 ships Squat capture only. The selection is local entry-flow
  /// state (Seam 3) — it never crosses into the capture feature.
  String _selectedMovementId = 'squat';

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeSessionProvider);
    final spots = ref.watch(nearbySpotsProvider);
    final movements = ref.watch(movementsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Workout')),
      body: ListView(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        children: [
          _SessionCard(session: session),
          const SizedBox(height: RepRushTokens.spaceMd),
          Text('Movement', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: RepRushTokens.spaceSm),
          movements.when(
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(movementsProvider),
            ),
            data: (list) => Wrap(
              spacing: RepRushTokens.spaceSm,
              runSpacing: RepRushTokens.spaceSm,
              children: [
                for (final movement in list)
                  ChoiceChip(
                    label: Text(movement.id.replaceAll('_', ' ')),
                    selected: movement.id == _selectedMovementId,
                    onSelected: (_) =>
                        setState(() => _selectedMovementId = movement.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: RepRushTokens.spaceMd),
          if (session != null && _selectedMovementId == 'squat')
            // A's single entry point, embedded once the one-shot session is
            // open and Squat is selected.
            const AspectRatio(aspectRatio: 3 / 4, child: CapturePreviewScreen())
          else if (session != null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(RepRushTokens.spaceMd),
                child: Text(
                  'Only Squat is capture-ready in Slice 1 — pick Squat to '
                  'open the camera.',
                ),
              ),
            )
          else
            const CapturePlaceholder(),
          const SizedBox(height: RepRushTokens.spaceLg),
          Text('Nearby spots', style: Theme.of(context).textTheme.titleMedium),
          spots.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(RepRushTokens.spaceMd),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(nearbySpotsProvider),
            ),
            data: (list) => Card(
              child: Column(
                children: [
                  for (final spot in list)
                    ListTile(
                      leading: const Icon(Icons.place_outlined),
                      title: Text(spot.name),
                      subtitle: Text(
                        spot.verified
                            ? 'Verified · ${spot.distanceM?.round() ?? '?'} m'
                            : 'Unverified — needs 3 athletes (E6)',
                      ),
                      trailing: spot.holderHandle == null
                          ? null
                          : Text('held by ${spot.holderHandle}'),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends ConsumerWidget {
  const _SessionCard({required this.session});

  final SessionStart? session;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = session;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        child: active == null
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'No active session',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: RepRushTokens.spaceXs),
                  const Text(
                    'A session is one-shot (I2): the server issues the id, '
                    'records the start context, and submit consumes it.',
                  ),
                  const SizedBox(height: RepRushTokens.spaceMd),
                  FilledButton.icon(
                    onPressed: () =>
                        ref.read(activeSessionProvider.notifier).start(),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Start session'),
                  ),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Session active',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: RepRushTokens.spaceXs),
                  Text('id: ${active.sessionId}'),
                  Text('hex: ${active.hexH3}'),
                  Text('spot: ${active.spotId ?? '—'}'),
                  Text(
                    'movementConfigVersion: ${active.movementConfigVersion}',
                  ),
                ],
              ),
      ),
    );
  }
}
