/// Workout screen — session lifecycle plus the capture entry point (C1, C2).
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/ui/capture_placeholder.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/spots/data/spots_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';

class WorkoutScreen extends ConsumerWidget {
  const WorkoutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(activeSessionProvider);
    final spots = ref.watch(nearbySpotsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Workout')),
      body: ListView(
        padding: const EdgeInsets.all(RepRushTokens.spaceMd),
        children: [
          _SessionCard(session: session),
          const SizedBox(height: RepRushTokens.spaceMd),
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
