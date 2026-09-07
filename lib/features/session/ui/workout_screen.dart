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
import 'package:reprush/shared/widgets/widgets.dart';

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
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            title: const Text('Workout'),
            actions: [
              if (session != null)
                const Padding(
                  padding: EdgeInsets.only(right: RepRushTokens.spaceMd),
                  child: Chip(avatar: Icon(Icons.circle, color: RepRushTokens.brand, size: 10), label: Text('LIVE')),
                ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.all(RepRushTokens.spaceMd),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
          _SessionCard(session: session),
          const SizedBox(height: RepRushTokens.spaceMd),
          Text('Choose your movement', style: RepRushTokens.sectionTitle),
          const SizedBox(height: RepRushTokens.spaceSm),
          movements.when(
            loading: () => const LoadingView(),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(movementsProvider),
            ),
            data: (list) => SizedBox(
              height: 146,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(width: RepRushTokens.spaceSm),
                itemBuilder: (context, index) {
                  final movement = list[index];
                  return MovementChip(
                    movement: movement,
                    selected: movement.id == _selectedMovementId,
                    onTap: () => setState(() => _selectedMovementId = movement.id),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: RepRushTokens.spaceMd),
          if (session != null && _selectedMovementId == 'squat')
            // A's single entry point, embedded once the one-shot session is
            // open and Squat is selected.
            const AspectRatio(aspectRatio: 3 / 4, child: CapturePreviewScreen())
          else if (session != null)
            const GlassCard(
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
          Text('Train at a spot', style: RepRushTokens.sectionTitle),
          spots.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(RepRushTokens.spaceMd),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => ErrorView(
              error: error,
              onRetry: () => ref.invalidate(nearbySpotsProvider),
            ),
            data: (list) => SizedBox(
              height: 86,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: list.length,
                separatorBuilder: (_, _) => const SizedBox(width: RepRushTokens.spaceSm),
                itemBuilder: (context, index) {
                  final spot = list[index];
                  return GlassCard(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.place, color: RepRushTokens.brand),
                      const SizedBox(width: 8),
                      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                        Text(spot.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(spot.verified ? '${spot.distanceM?.round() ?? '?'} m · Verified' : 'Unverified', style: RepRushTokens.bodyLabel),
                      ]),
                    ]),
                  );
                },
              ),
            ),
          ),
              ]),
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
    return GlassCard(
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
                  BrandButton(
                    icon: Icons.play_arrow,
                    label: 'Start session',
                    onPressed: () =>
                        ref.read(activeSessionProvider.notifier).start(),
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
