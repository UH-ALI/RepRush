/// Territory map with server-provided H3 polygons over OpenStreetMap tiles.
///
/// Location rules the map enforces in the UI (the server enforces them for
/// real — territory always resolves from the session's recorded start fix):
///
///   - the hex you are standing in is outlined and named in the status pill;
///   - only that hex offers "Train here" — every other hex shows how far away
///     it is instead of a button that could never pay out;
///   - the grid re-fetches around you once you walk out of the loaded area.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/spots/data/spots_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

/// A one-shot request for the map to fly to a hex and select it — set by the
/// post-set summary's "See it on the map", cleared by the map once handled.
class MapFocusController extends Notifier<String?> {
  @override
  String? build() => null;

  void focus(String h3) => state = h3;

  void clear() => state = null;
}

final mapFocusProvider = NotifierProvider<MapFocusController, String?>(
  MapFocusController.new,
);

const double _defaultZoom = 14.2;
const double _focusZoom = 15.2;

class MapScreen extends ConsumerWidget {
  const MapScreen({required this.onOpenWorkout, super.key});

  final Future<void> Function(HexCell cell) onOpenWorkout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = ref.watch(territoryLocationProvider);
    final hexes = ref.watch(hexesProvider);
    final spots = ref.watch(nearbySpotsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Territory')),
      // skipLoadingOnReload: re-anchoring after a long walk swaps the grid in
      // place rather than blanking the whole map behind a spinner.
      body: location.when(
        skipLoadingOnReload: true,
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(territoryLocationProvider),
        ),
        data: (resolvedLocation) => hexes.when(
          skipLoadingOnReload: true,
          loading: () => const LoadingView(),
          error: (error, _) => ErrorView(
            error: error,
            onRetry: () => ref.invalidate(hexesProvider),
          ),
          data: (cells) => _MapView(
            cells: cells,
            spots: spots.value ?? const [],
            location: resolvedLocation,
            onOpenWorkout: onOpenWorkout,
          ),
        ),
      ),
    );
  }
}

class _MapView extends ConsumerStatefulWidget {
  const _MapView({
    required this.cells,
    required this.spots,
    required this.location,
    required this.onOpenWorkout,
  });

  final List<HexCell> cells;
  final List<SpotSummary> spots;

  /// The anchor the grid was fetched around — not necessarily where the
  /// athlete is now (that is [hereProvider]).
  final SessionLocation location;
  final Future<void> Function(HexCell cell) onOpenWorkout;

  @override
  ConsumerState<_MapView> createState() => _MapViewState();
}

class _MapViewState extends ConsumerState<_MapView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();
  late final ValueNotifier<LayerHitResult<HexCell>?> _hitNotifier =
      ValueNotifier(null);
  final MapController _mapController = MapController();
  String? _selectedHex;

  /// Set while a re-anchor fetch is in flight, so a stream of fixes beyond
  /// [reanchorDistanceM] triggers one refetch rather than one per fix.
  bool _reanchoring = false;

  @override
  void initState() {
    super.initState();
    // A focus request can arrive while the map is still loading (the summary
    // invalidates the grid and switches tabs in the same frame).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = ref.read(mapFocusProvider);
      if (pending != null) _focusHex(pending);
    });
  }

  @override
  void didUpdateWidget(_MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) _reanchoring = false;
  }

  @override
  void dispose() {
    _pulse.dispose();
    _hitNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AsyncValue<SessionLocation>>(currentLocationProvider, (_, next) {
      final fix = next.value;
      if (fix == null || _reanchoring) return;
      final moved = distanceM(
        widget.location.lat,
        widget.location.lng,
        fix.lat,
        fix.lng,
      );
      if (moved > reanchorDistanceM) {
        _reanchoring = true;
        ref.invalidate(territoryLocationProvider);
      }
    });
    ref.listen<String?>(mapFocusProvider, (_, h3) {
      if (h3 != null) _focusHex(h3);
    });

    final here = ref.watch(hereProvider) ?? widget.location;
    final current = ref.watch(currentHexProvider);
    final cells = widget.cells;
    final yours = cells.where((c) => c.yours).length;
    final rivals = cells.where((c) => !c.yours && c.ownerHandle != null).length;
    final open = cells.length - yours - rivals;

    // Highlighted cells draw last so their outline is not painted over by a
    // neighbour's border.
    int drawOrder(HexCell c) => c.h3 == _selectedHex
        ? 2
        : c.h3 == current?.h3
        ? 1
        : 0;
    final ordered = [...cells]
      ..sort((a, b) => drawOrder(a).compareTo(drawOrder(b)));

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            initialCenter: LatLng(here.lat, here.lng),
            initialZoom: _defaultZoom,
            onTap: (_, _) => _onHexTap(),
          ),
          mapController: _mapController,
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.repush.app',
            ),
            PolygonLayer(
              polygons: [
                for (final cell in ordered) _polygonFor(cell, current),
              ],
              hitNotifier: _hitNotifier,
            ),
            MarkerLayer(
              markers: [
                for (final spot in widget.spots) _spotMarker(spot),
                Marker(
                  point: LatLng(here.lat, here.lng),
                  width: 52,
                  height: 52,
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (context, child) => Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: RepRushTokens.brand.withValues(alpha: .16),
                        border: Border.all(
                          color: RepRushTokens.brand.withValues(
                            alpha: .45 + (_pulse.value * .4),
                          ),
                          width: 2 + (_pulse.value * 3),
                        ),
                      ),
                      child: const Icon(
                        Icons.my_location,
                        color: RepRushTokens.brand,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        Positioned(
          left: RepRushTokens.spaceMd,
          right: RepRushTokens.spaceMd,
          top: RepRushTokens.spaceMd,
          child: Row(
            children: [
              _MapPill(
                icon: Icons.hexagon,
                text: '$yours OWNED',
                color: RepRushTokens.brand,
              ),
              const Spacer(),
              _CurrentHexPill(
                current: current,
                onTap: current == null ? null : () => _openSheet(current),
              ),
            ],
          ),
        ),
        Positioned(
          left: RepRushTokens.spaceMd,
          right: RepRushTokens.spaceMd,
          bottom: RepRushTokens.spaceMd,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                '© OpenStreetMap contributors',
                style: TextStyle(color: Colors.white70, fontSize: 9),
              ),
              const SizedBox(height: 4),
              GlassCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _MapLegend(ownership: Ownership.yours, count: yours),
                    _MapLegend(ownership: Ownership.rival, count: rivals),
                    _MapLegend(ownership: Ownership.unclaimed, count: open),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: RepRushTokens.spaceMd,
          top: 68,
          child: Column(
            children: [
              const _LeaderboardButton(),
              const SizedBox(height: RepRushTokens.spaceSm),
              _MapControls(
                onZoomIn: () => _mapController.move(
                  _mapController.camera.center,
                  _mapController.camera.zoom + .7,
                ),
                onZoomOut: () => _mapController.move(
                  _mapController.camera.center,
                  _mapController.camera.zoom - .7,
                ),
                onRecenter: () =>
                    _mapController.move(LatLng(here.lat, here.lng), _defaultZoom),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Polygon<HexCell> _polygonFor(HexCell cell, HexCell? current) {
    final unclaimed = cell.ownerHandle == null && !cell.yours;
    final isCurrent = cell.h3 == current?.h3;
    final isSelected = cell.h3 == _selectedHex;
    return Polygon<HexCell>(
      points: [for (final point in cell.polygon) LatLng(point.lat, point.lng)],
      color: Ownership.fromWire(
        ownerHandle: cell.ownerHandle,
        yours: cell.yours,
      ).color.withValues(alpha: unclaimed ? .20 : .38),
      borderColor: isSelected
          ? Colors.white
          : isCurrent
          ? RepRushTokens.brand
          : Colors.black.withValues(alpha: .78),
      borderStrokeWidth: isSelected
          ? 4
          : isCurrent
          ? 3.5
          : unclaimed
          ? 1.2
          : 1.8,
      hitValue: cell,
    );
  }

  Marker _spotMarker(SpotSummary spot) => Marker(
    // The stub's seeded rig sits exactly on the demo venue fix; nudge it so the
    // athlete marker does not hide it.
    point: LatLng(
      spot.lat == DemoVenue.lat && spot.lng == DemoVenue.lng
          ? spot.lat + .0008
          : spot.lat,
      spot.lng,
    ),
    width: 44,
    height: 52,
    child: GestureDetector(
      onTap: () => _showSpot(spot),
      child: Column(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: spot.verified
                  ? RepRushTokens.electricViolet
                  : RepRushTokens.surfaceRaised,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
              boxShadow: RepRushTokens.cardShadow,
            ),
            child: Padding(
              padding: const EdgeInsets.all(7),
              child: Icon(_spotIcon(spot.type), size: 18, color: Colors.white),
            ),
          ),
          Flexible(
            child: Text(
              spot.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                shadows: [Shadow(blurRadius: 3)],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  void _onHexTap() {
    final hit = _hitNotifier.value;
    if (hit == null || hit.hitValues.isEmpty || !mounted) return;
    final cell = hit.hitValues.first;
    _hitNotifier.value = null;
    _openSheet(cell);
  }

  void _openSheet(HexCell cell) {
    setState(() => _selectedHex = cell.h3);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      isScrollControlled: true,
      builder: (_) =>
          _HexSheet(cell: cell, onOpenWorkout: widget.onOpenWorkout),
    );
  }

  void _focusHex(String h3) {
    ref.read(mapFocusProvider.notifier).clear();
    final cell = widget.cells.where((c) => c.h3 == h3).firstOrNull;
    if (cell == null || !mounted) return;
    final centre = polygonCentre(cell.polygon);
    setState(() => _selectedHex = h3);
    _mapController.move(LatLng(centre.lat, centre.lng), _focusZoom);
  }

  void _showSpot(SpotSummary spot) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(RepRushTokens.spaceLg),
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              _spotIcon(spot.type),
              color: RepRushTokens.electricViolet,
            ),
            title: Text(spot.name),
            subtitle: Text(
              '${spot.verified ? 'Verified' : 'Unverified'} spot'
              '${spot.holderHandle == null ? '' : ' · held by ${spot.holderHandle}'}',
            ),
          ),
        ),
      ),
    );
  }

  IconData _spotIcon(SpotType type) => switch (type) {
    SpotType.calisthenicsPark => Icons.sports_gymnastics,
    SpotType.gym => Icons.sports_gymnastics,
    SpotType.pullUpBar => Icons.horizontal_rule,
    SpotType.playground => Icons.child_friendly,
    SpotType.custom => Icons.place,
  };
}

/// Top-right status: which kind of hex you are standing in. Tapping it opens
/// that hex's sheet — the quickest route to "Train here".
class _CurrentHexPill extends StatelessWidget {
  const _CurrentHexPill({required this.current, required this.onTap});

  final HexCell? current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cell = current;
    if (cell == null) {
      return const _MapPill(
        icon: Icons.gps_not_fixed,
        text: 'LOCATING…',
        color: Colors.white,
      );
    }
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
    final text = switch (ownership) {
      Ownership.yours => 'IN YOUR HEX',
      Ownership.rival => 'IN RIVAL HEX',
      Ownership.unclaimed => 'IN OPEN HEX',
    };
    return GestureDetector(
      onTap: onTap,
      child: _MapPill(icon: Icons.my_location, text: text, color: ownership.color),
    );
  }
}

class _MapControls extends StatelessWidget {
  const _MapControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRecenter,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRecenter;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .94),
      borderRadius: BorderRadius.circular(14),
      boxShadow: RepRushTokens.cardShadow,
    ),
    child: Column(
      children: [
        IconButton(
          tooltip: 'Zoom in',
          onPressed: onZoomIn,
          color: RepRushTokens.surfaceDark,
          icon: const Icon(Icons.add),
        ),
        const Divider(height: 1),
        IconButton(
          tooltip: 'Recenter on me',
          onPressed: onRecenter,
          color: RepRushTokens.brandDark,
          icon: const Icon(Icons.my_location),
        ),
        const Divider(height: 1),
        IconButton(
          tooltip: 'Zoom out',
          onPressed: onZoomOut,
          color: RepRushTokens.surfaceDark,
          icon: const Icon(Icons.remove),
        ),
      ],
    ),
  );
}

/// The hex detail sheet. Only the hex the athlete is standing in can be
/// trained for; any other hex explains how far away it is instead.
class _HexSheet extends ConsumerWidget {
  const _HexSheet({required this.cell, required this.onOpenWorkout});

  final HexCell cell;
  final Future<void> Function(HexCell cell) onOpenWorkout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(currentHexProvider);
    final here = ref.watch(hereProvider);
    final sessionActive = ref.watch(activeSessionProvider) != null;
    final isHere = current?.h3 == cell.h3;
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
    final power = cell.power.round();

    final title = switch (ownership) {
      Ownership.yours => 'Your hex',
      Ownership.rival => 'Held by ${cell.ownerHandle}',
      Ownership.unclaimed => 'Unclaimed hex',
    };
    final body = switch (ownership) {
      Ownership.yours =>
        'You hold it with $power power. Power fades over 72 hours, so train '
            'here to keep it.',
      Ownership.rival => '$power power. Out-train them here to take it.',
      Ownership.unclaimed =>
        'Nobody holds this hex yet. One solid set here claims it.',
    };
    final actionLabel = sessionActive
        ? 'Continue your set'
        : switch (ownership) {
            Ownership.yours => 'Defend this hex',
            Ownership.rival => 'Take this hex',
            Ownership.unclaimed => 'Claim this hex',
          };

    String? distance;
    if (!isHere && here != null) {
      final centre = polygonCentre(cell.polygon);
      distance = formatDistance(
        distanceM(here.lat, here.lng, centre.lat, centre.lng),
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(ownership.icon, color: ownership.color),
                const SizedBox(width: RepRushTokens.spaceSm),
                Flexible(
                  child: Text(
                    title,
                    style: RepRushTokens.sectionTitle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isHere) ...[
                  const SizedBox(width: RepRushTokens.spaceSm),
                  const _HereBadge(),
                ],
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            Text(body, style: Theme.of(context).textTheme.bodyLarge),
            if (distance != null) ...[
              const SizedBox(height: RepRushTokens.spaceSm),
              Row(
                children: [
                  const Icon(Icons.near_me, size: 16, color: Colors.white70),
                  const SizedBox(width: 6),
                  Text('$distance away', style: RepRushTokens.bodyLabel),
                ],
              ),
            ],
            const SizedBox(height: RepRushTokens.spaceMd),
            if (isHere)
              BrandButton(
                label: actionLabel,
                icon: Icons.sports_gymnastics,
                onPressed: () async {
                  Navigator.pop(context);
                  await onOpenWorkout(cell);
                },
              )
            else ...[
              const BrandButton(
                label: 'Go there to train',
                icon: Icons.directions_walk,
                onPressed: null,
              ),
              const SizedBox(height: RepRushTokens.spaceSm),
              Text(
                "You can only train for the hex you're standing in.",
                style: RepRushTokens.bodyLabel,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HereBadge extends StatelessWidget {
  const _HereBadge();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: RepRushTokens.brand.withValues(alpha: .16),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: RepRushTokens.brand.withValues(alpha: .6)),
    ),
    child: const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: Text(
        "YOU'RE HERE",
        style: TextStyle(
          color: RepRushTokens.brand,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
  );
}

class _LeaderboardButton extends ConsumerWidget {
  const _LeaderboardButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Leaderboard',
    style: IconButton.styleFrom(
      backgroundColor: const Color(0xDD0C1511),
      foregroundColor: RepRushTokens.brand,
    ),
    icon: const Icon(Icons.leaderboard),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      builder: (_) => const SafeArea(
        child: Padding(
          padding: EdgeInsets.all(RepRushTokens.spaceMd),
          child: _LeaderboardList(),
        ),
      ),
    ),
  );
}

class _MapPill extends StatelessWidget {
  const _MapPill({required this.icon, required this.text, required this.color});
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xDD0C1511),
      borderRadius: BorderRadius.circular(99),
      border: Border.all(color: color.withValues(alpha: .55)),
      boxShadow: RepRushTokens.cardShadow,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    ),
  );
}

class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.ownership, required this.count});
  final Ownership ownership;
  final int count;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(ownership.icon, color: ownership.color, size: 16),
      const SizedBox(width: 4),
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            ownership.label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
          Text(
            '$count hexes',
            style: const TextStyle(fontSize: 9, color: Colors.white70),
          ),
        ],
      ),
    ],
  );
}

class _LeaderboardList extends ConsumerWidget {
  const _LeaderboardList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final board = ref.watch(leaderboardProvider);
    return board.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(RepRushTokens.spaceMd),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => ErrorView(
        error: error,
        onRetry: () => ref.invalidate(leaderboardProvider),
      ),
      data: (rows) => rows.isEmpty
          ? const EmptyView(
              message: 'No one holds territory yet. Be the first to claim a hex.',
            )
          : Card(
              child: Column(
                children: [
                  for (final row in rows)
                    ListTile(
                      leading: Text('${row.rank}'),
                      title: Text(row.handle),
                      trailing: Text(
                        '${row.hexesHeld} hexes · '
                        '${row.areaKm2.toStringAsFixed(1)} km²',
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
