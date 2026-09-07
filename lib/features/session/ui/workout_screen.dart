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
import 'package:reprush/core/location/location.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/ui/capture_placeholder.dart';
import 'package:reprush/features/capture/ui/capture_preview_screen.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/spots/data/spots_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

// ---------------------------------------------------------------------------
// Movements that have a capture-ready pipeline config on the client.
// When the user selects one of these and a session is active, the live
// camera is shown. All other movements in the catalogue get an informational
// card — add entries here as new MovementConfigs land in Track A.
// ---------------------------------------------------------------------------
const Map<String, MovementConfig> _captureReadyConfigs = {
  'squat': squatConfig,
  'push_up': pushUpConfig,
  'pull_up': pullUpConfig,
};

class WorkoutScreen extends ConsumerStatefulWidget {
  const WorkoutScreen({super.key});

  @override
  ConsumerState<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends ConsumerState<WorkoutScreen>
    with SingleTickerProviderStateMixin {
  /// Local movement selection state (Seam 3) — updated by the movement chip
  /// list and used to gate capture. Defaults to squat (first capture-ready
  /// movement). Never crosses into the capture feature directly.
  String _selectedMovementId = 'squat';
  late final AnimationController _energy;

  @override
  void initState() {
    super.initState();
    _energy = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..forward();
  }

  @override
  void dispose() {
    _energy.dispose();
    super.dispose();
  }

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
                Padding(
                  padding: const EdgeInsets.only(right: RepRushTokens.spaceMd),
                  child: AnimatedBuilder(
                    animation: _energy,
                    builder: (context, child) => Transform.scale(
                      scale: 1 + (_energy.value * .04),
                      child: child,
                    ),
                    child: const Chip(
                      avatar: Icon(
                        Icons.circle,
                        color: RepRushTokens.brand,
                        size: 10,
                      ),
                      label: Text('LIVE'),
                    ),
                  ),
                ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.all(RepRushTokens.spaceMd),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: RepRushTokens.medium,
                  curve: Curves.easeOutCubic,
                  builder: (context, value, child) => Opacity(
                    opacity: value,
                    child: Transform.translate(
                      offset: Offset(0, 18 * (1 - value)),
                      child: child,
                    ),
                  ),
                  child: _SessionCard(session: session),
                ),
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
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: RepRushTokens.spaceSm),
                      itemBuilder: (context, index) {
                        final movement = list[index];
                        return MovementChip(
                          movement: movement,
                          selected: movement.id == _selectedMovementId,
                          onTap: () =>
                              setState(() => _selectedMovementId = movement.id),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: RepRushTokens.spaceMd),
                // Show the camera when a session is active AND the selected movement
                // has a capture-ready pipeline config. Otherwise show an informational
                // card (movement not yet supported) or the pre-session placeholder.
                if (session != null &&
                    _captureReadyConfigs.containsKey(_selectedMovementId))
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: CapturePreviewScreen(
                      config: _captureReadyConfigs[_selectedMovementId]!,
                    ),
                  )
                else if (session != null)
                  GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(RepRushTokens.spaceMd),
                      child: Text(
                        '${_selectedMovementId.replaceAll("_", " ")} is not yet '
                        'capture-ready — select Squat, Push-up, or Pull-up to open the camera.',
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
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: RepRushTokens.spaceSm),
                      itemBuilder: (context, index) {
                        final spot = list[index];
                        return GlassCard(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.place,
                                color: RepRushTokens.brand,
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    spot.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
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
                    onPressed: () async {
                      try {
                        final location = await readSessionLocation();
                        await ref
                            .read(activeSessionProvider.notifier)
                            .start(location: location);
                      } on LocationException catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(error.message)));
                      } on ApiException catch (error) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('${error.code}: ${error.message}'),
                          ),
                        );
                      }
                    },
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
