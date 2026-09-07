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
import 'package:reprush/core/api/api_providers.dart';
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
  bool _isStartingSession = false;
  String? _startSessionStatus;
  String? _selectedSpotId;

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

  Future<void> _handleStartSession({String? spotId}) async {
    if (_isStartingSession) return;
    setState(() {
      _isStartingSession = true;
      _startSessionStatus = 'Acquiring GPS fix...';
    });
    try {
      final location = await readSessionLocation(
        ref.read(backendConfigProvider),
      );
      if (!mounted) return;
      setState(() {
        _startSessionStatus = 'Starting session...';
      });
      await ref.read(activeSessionProvider.notifier).start(
        location: location,
        spotId: spotId ?? _selectedSpotId,
      );
    } on LocationException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${error.code}: ${error.message}')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start session: $error')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isStartingSession = false;
          _startSessionStatus = null;
        });
      }
    }
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
                  child: _SessionCard(
                    session: session,
                    onStart: _handleStartSession,
                    isStarting: _isStartingSession,
                    statusMessage: _startSessionStatus,
                  ),
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
                  CapturePlaceholder(
                    onStartWorkout:
                        _captureReadyConfigs.containsKey(_selectedMovementId)
                            ? _handleStartSession
                            : null,
                    isStarting: _isStartingSession,
                    statusMessage: _startSessionStatus,
                    selectedMovementName: _selectedMovementId,
                  ),
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
                        final isSelected = spot.id == _selectedSpotId;
                        return GlassCard(
                          glow: isSelected,
                          onTap: () {
                            setState(() {
                              _selectedSpotId = isSelected ? null : spot.id;
                            });
                          },
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.place,
                                color: isSelected
                                    ? RepRushTokens.brand
                                    : RepRushTokens.brand.withValues(alpha: 0.7),
                              ),
                              const SizedBox(width: 8),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    spot.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: isSelected ? RepRushTokens.brand : null,
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
                              if (isSelected) ...[
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.check_circle,
                                  size: 16,
                                  color: RepRushTokens.brand,
                                ),
                              ],
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

class _SessionCard extends StatelessWidget {
  const _SessionCard({
    required this.session,
    required this.onStart,
    this.isStarting = false,
    this.statusMessage,
  });

  final SessionStart? session;
  final VoidCallback onStart;
  final bool isStarting;
  final String? statusMessage;

  @override
  Widget build(BuildContext context) {
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
                  if (isStarting)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: RepRushTokens.spaceSm),
                        Text(
                          statusMessage ?? 'Starting session...',
                          style: RepRushTokens.bodyLabel,
                        ),
                      ],
                    )
                  else
                    BrandButton(
                      icon: Icons.play_arrow,
                      label: 'Start session',
                      onPressed: onStart,
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
