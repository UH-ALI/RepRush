/// Workout screen — session lifecycle, movement selection, and the capture
/// entry point (C1, C2). Seam 3 (roles.md §4): C owns how you get in —
/// movement picker and session context — and A owns the capture screen
/// itself.
///
/// A session always starts from where the athlete is standing, through
/// [ActiveSessionController.startHere] — the same gate the map's "Train here"
/// uses — and the card says which hex the set will count for before it starts.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/ui/capture_placeholder.dart';
import 'package:reprush/features/capture/ui/capture_preview_screen.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/session/ui/session_summary_screen.dart';
import 'package:reprush/features/spots/data/spots_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/errors.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

// ---------------------------------------------------------------------------
// Movements that have a capture-ready pipeline config on the client. Only
// these are offered in the picker: a movement the camera cannot count would be
// a dead end mid-workout. Add entries as new MovementConfigs land in Track A.
// ---------------------------------------------------------------------------
const Map<String, MovementConfig> _captureReadyConfigs = {
  'squat': squatConfig,
  'push_up': pushUpConfig,
  'pull_up': pullUpConfig,
};

class WorkoutScreen extends ConsumerStatefulWidget {
  const WorkoutScreen({super.key, this.visible = true, this.onShowOnMap});

  /// False while another tab is showing; the camera pauses meanwhile.
  final bool visible;

  /// Switches to the map focused on a hex ("See it on the map").
  final void Function(String h3)? onShowOnMap;

  @override
  ConsumerState<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends ConsumerState<WorkoutScreen>
    with SingleTickerProviderStateMixin {
  /// Local movement selection state (Seam 3) — updated by the movement chip
  /// list and used to gate capture. Never crosses into the capture feature
  /// directly. Locked while a session is open.
  String _selectedMovementId = 'squat';
  bool _starting = false;
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

  Future<void> _start() async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      await ref.read(activeSessionProvider.notifier).startHere();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeError(error))));
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _cancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End this set?'),
        content: const Text(
          "Reps from this set won't count, and it won't affect any territory.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep going'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End set'),
          ),
        ],
      ),
    );
    if (confirmed == true) ref.read(activeSessionProvider.notifier).abandon();
  }

  void _onSubmitted(SubmitResult result, int repCount) {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionSummaryScreen(
          result: result,
          repCount: repCount,
          movementId: _selectedMovementId,
          onShowOnMap: widget.onShowOnMap,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(activeSessionProvider);
    final spots = ref.watch(nearbySpotsProvider);
    final movements = ref.watch(movementsProvider);
    final locked = session != null;
    final config = _captureReadyConfigs[_selectedMovementId];
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
                    movementId: _selectedMovementId,
                    starting: _starting,
                    onStart: _start,
                    onCancel: _cancel,
                  ),
                ),
                const SizedBox(height: RepRushTokens.spaceMd),
                Text('Choose your movement', style: RepRushTokens.sectionTitle),
                if (locked)
                  Padding(
                    padding: const EdgeInsets.only(top: RepRushTokens.spaceXs),
                    child: Text(
                      'Finish or end your set to switch exercise.',
                      style: RepRushTokens.bodyLabel,
                    ),
                  ),
                const SizedBox(height: RepRushTokens.spaceSm),
                movements.when(
                  loading: () => const LoadingView(),
                  error: (error, _) => ErrorView(
                    error: error,
                    onRetry: () => ref.invalidate(movementsProvider),
                  ),
                  data: (list) {
                    final ready = [
                      for (final id in _captureReadyConfigs.keys)
                        ...list.where((m) => m.id == id),
                    ];
                    return SizedBox(
                      height: 146,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: ready.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(width: RepRushTokens.spaceSm),
                        itemBuilder: (context, index) {
                          final movement = ready[index];
                          return MovementChip(
                            movement: movement,
                            selected: movement.id == _selectedMovementId,
                            onTap: locked
                                ? null
                                : () => setState(
                                    () => _selectedMovementId = movement.id,
                                  ),
                          );
                        },
                      ),
                    );
                  },
                ),
                const SizedBox(height: RepRushTokens.spaceMd),
                if (session != null && config != null)
                  AspectRatio(
                    aspectRatio: 3 / 4,
                    child: CapturePreviewScreen(
                      // A new session or movement is a new pipeline: the
                      // capture view starts its pipeline once, in initState.
                      key: ValueKey(
                        '${session.sessionId}/$_selectedMovementId',
                      ),
                      config: config,
                      active: widget.visible,
                      onSubmitted: _onSubmitted,
                    ),
                  )
                else
                  const CapturePlaceholder(),
                ...spots.maybeWhen(
                  data: (list) => list.isEmpty
                      ? const <Widget>[]
                      : [
                          const SizedBox(height: RepRushTokens.spaceLg),
                          Text(
                            'Spots nearby',
                            style: RepRushTokens.sectionTitle,
                          ),
                          const SizedBox(height: RepRushTokens.spaceSm),
                          _SpotStrip(spots: list),
                        ],
                  orElse: () => const <Widget>[],
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

/// Where the set will count, and the button that starts it.
class _SessionCard extends ConsumerWidget {
  const _SessionCard({
    required this.session,
    required this.movementId,
    required this.starting,
    required this.onStart,
    required this.onCancel,
  });

  final SessionStart? session;
  final String movementId;
  final bool starting;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = session;
    final titleStyle = Theme.of(context).textTheme.titleMedium;

    if (active == null) {
      final current = ref.watch(currentHexProvider);
      return GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Ready to train', style: titleStyle),
            const SizedBox(height: RepRushTokens.spaceXs),
            _HexLine(cell: current, active: false),
            const SizedBox(height: RepRushTokens.spaceMd),
            BrandButton(
              icon: Icons.play_arrow,
              label: 'Start ${movementDisplayName(movementId).toLowerCase()}s',
              loading: starting,
              onPressed: onStart,
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            const _PrivacyLine(),
          ],
        ),
      );
    }

    // The session's hex is the one the SERVER recorded at start — the hex the
    // set will count for, whatever the athlete does next.
    final sessionHex = ref
        .watch(hexesProvider)
        .value
        ?.where((c) => c.h3 == active.hexH3)
        .firstOrNull;
    return GlassCard(
      glow: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Training · ${movementDisplayName(movementId)}',
                  style: titleStyle,
                ),
              ),
              TextButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.close, size: 18),
                label: const Text('End set'),
              ),
            ],
          ),
          const SizedBox(height: RepRushTokens.spaceXs),
          _HexLine(cell: sessionHex, active: true),
          const SizedBox(height: RepRushTokens.spaceXs),
          Text(
            'Get your whole body in frame, then tap Finish when your set is '
            'done.',
            style: RepRushTokens.bodyLabel,
          ),
        ],
      ),
    );
  }
}

/// One line describing a hex in athlete terms.
class _HexLine extends StatelessWidget {
  const _HexLine({required this.cell, required this.active});

  final HexCell? cell;

  /// True once a session is open: "counts for" rather than "you're in".
  final bool active;

  @override
  Widget build(BuildContext context) {
    final cell = this.cell;
    if (cell == null) {
      return Row(
        children: [
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: RepRushTokens.spaceSm),
          Text(
            active ? 'This set counts for the hex you are in.' : 'Finding your hex…',
            style: RepRushTokens.bodyLabel,
          ),
        ],
      );
    }
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
    final power = cell.power.round();
    final text = switch (ownership) {
      Ownership.yours =>
        active
            ? 'Counts for your hex ($power power). Every rep keeps it strong.'
            : "You're in your hex ($power power). Train to keep it strong.",
      Ownership.rival =>
        active
            ? "Counts for ${cell.ownerHandle}'s hex ($power power). Beat it to "
                  'take over.'
            : "You're in ${cell.ownerHandle}'s hex ($power power). Out-train "
                  'them to take it.',
      Ownership.unclaimed =>
        active
            ? 'Counts for this unclaimed hex. A solid set claims it.'
            : "You're in an unclaimed hex. One solid set claims it.",
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(ownership.icon, size: 18, color: ownership.color),
        const SizedBox(width: RepRushTokens.spaceSm),
        Expanded(child: Text(text)),
      ],
    );
  }
}

class _PrivacyLine extends StatelessWidget {
  const _PrivacyLine();

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
