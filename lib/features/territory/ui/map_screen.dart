/// Territory map with server-provided H3 polygons over OpenStreetMap tiles.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hexes = ref.watch(hexesProvider);
    final spots = ref.watch(nearbySpotsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Territory')),
      body: hexes.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(hexesProvider),
        ),
        data: (cells) => spots.when(
          loading: () => _MapView(cells: cells, spots: const []),
          error: (error, _) => _MapView(cells: cells, spots: const []),
          data: (nearby) => _MapView(cells: cells, spots: nearby),
        ),
      ),
    );
  }
}

class _MapView extends ConsumerStatefulWidget {
  const _MapView({required this.cells, required this.spots});

  final List<HexCell> cells;
  final List<SpotSummary> spots;

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

  @override
  void dispose() {
    _pulse.dispose();
    _hitNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cells = widget.cells;
    final yours = cells.where((c) => c.yours).length;
    final rivals = cells.where((c) => !c.yours && c.ownerHandle != null).length;
    final open = cells.length - yours - rivals;
    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            initialCenter: LatLng(DemoVenue.lat, DemoVenue.lng),
            initialZoom: 14.2,
          ),
          mapController: _mapController,
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.repush.app',
            ),
            PolygonLayer(
              polygons: [
                for (final cell in cells)
                  Polygon<HexCell>(
                    points: [
                      for (final point in cell.polygon)
                        LatLng(point.lat, point.lng),
                    ],
                    color:
                        Ownership.fromWire(
                          ownerHandle: cell.ownerHandle,
                          yours: cell.yours,
                        ).color.withValues(
                          alpha: cell.ownerHandle == null && !cell.yours
                              ? .20
                              : .38,
                        ),
                    borderColor: cell.h3 == _selectedHex
                        ? Colors.white
                        : Ownership.fromWire(
                            ownerHandle: cell.ownerHandle,
                            yours: cell.yours,
                          ).color,
                    borderStrokeWidth: cell.h3 == _selectedHex
                        ? 4
                        : cell.ownerHandle == null && !cell.yours
                        ? .8
                        : 1.6,
                    hitValue: cell,
                  ),
              ],
              hitNotifier: _hitNotifier,
            ),
            MarkerLayer(
              markers: [
                for (final spot in widget.spots)
                  Marker(
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
                              child: Icon(
                                _spotIcon(spot.type),
                                size: 18,
                                color: Colors.white,
                              ),
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
                  ),
                Marker(
                  point: const LatLng(DemoVenue.lat, DemoVenue.lng),
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _MapPill(
                icon: Icons.hexagon,
                text: '$yours OWNED',
                color: RepRushTokens.brand,
              ),
              _MapPill(
                icon: Icons.my_location,
                text: 'LIVE ZONE',
                color: Colors.white,
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
          top: RepRushTokens.spaceMd,
          child: _LeaderboardButton(),
        ),
        Positioned(
          right: RepRushTokens.spaceMd,
          top: 72,
          child: _MapControls(
            onZoomIn: () => _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom + .7,
            ),
            onZoomOut: () => _mapController.move(
              _mapController.camera.center,
              _mapController.camera.zoom - .7,
            ),
            onRecenter: () => _mapController.move(
              const LatLng(DemoVenue.lat, DemoVenue.lng),
              14.2,
            ),
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _hitNotifier.addListener(_onHexHit);
  }

  void _onHexHit() {
    final hit = _hitNotifier.value;
    if (hit == null || hit.hitValues.isEmpty || !mounted) return;
    final cell = hit.hitValues.first;
    _hitNotifier.value = null;
    setState(() => _selectedHex = cell.h3);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      isScrollControlled: true,
      builder: (_) => _HexSheet(cell: cell),
    );
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
            trailing: const Icon(Icons.chevron_right),
          ),
        ),
      ),
    );
  }

  IconData _spotIcon(SpotType type) => switch (type) {
    SpotType.calisthenicsPark => Icons.fitness_center,
    SpotType.gym => Icons.sports_gymnastics,
    SpotType.pullUpBar => Icons.horizontal_rule,
    SpotType.playground => Icons.child_friendly,
    SpotType.custom => Icons.place,
  };
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

class _HexSheet extends ConsumerWidget {
  const _HexSheet({required this.cell});
  final HexCell cell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ownership = Ownership.fromWire(
      ownerHandle: cell.ownerHandle,
      yours: cell.yours,
    );
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
                Text(ownership.label, style: RepRushTokens.sectionTitle),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            Text(
              cell.ownerHandle == null
                  ? 'This hex is open for capture.'
                  : 'Held by ${cell.ownerHandle}.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: RepRushTokens.spaceSm),
            Text(
              'Power ${cell.power.toStringAsFixed(0)} · ${cell.h3}',
              style: RepRushTokens.bodyLabel,
            ),
            const SizedBox(height: RepRushTokens.spaceMd),
            BrandButton(
              label: cell.yours ? 'Train here' : 'Capture this hex',
              icon: Icons.fitness_center,
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
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
      data: (rows) => Card(
        child: Column(
          children: [
            for (final row in rows)
              ListTile(
                leading: Text('${row.rank}'),
                title: Text(row.handle),
                trailing: Text(
                  '${row.hexesHeld} hexes · ${row.areaKm2.toStringAsFixed(1)} km²',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
