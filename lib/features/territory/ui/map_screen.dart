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
    return Scaffold(
      appBar: AppBar(title: const Text('Territory')),
      body: hexes.when(
        loading: () => const LoadingView(),
        error: (error, _) => ErrorView(
          error: error,
          onRetry: () => ref.invalidate(hexesProvider),
        ),
        data: (cells) => _MapView(cells: cells),
      ),
    );
  }
}

class _MapView extends StatefulWidget {
  const _MapView({required this.cells});

  final List<HexCell> cells;

  @override
  State<_MapView> createState() => _MapViewState();
}

class _MapViewState extends State<_MapView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..forward();

  @override
  void dispose() {
    _pulse.dispose();
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
            initialCenter: LatLng(DemoVenue.lat, DemoVenue.lng),
            initialZoom: 14.2,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.repush.app',
              tileBuilder: (context, child, tile) => ColorFiltered(
                colorFilter: const ColorFilter.matrix(<double>[
                  .35, 0, 0, 0, 0,
                  0, .45, 0, 0, 0,
                  0, 0, .40, 0, 0,
                  0, 0, 0, 1, 0,
                ]),
                child: child,
              ),
            ),
            PolygonLayer(
              polygons: [
                for (final cell in cells)
                  Polygon<Object>(
                    points: [
                      for (final point in cell.polygon)
                        LatLng(point.lat, point.lng),
                    ],
                    color: Ownership.fromWire(
                      ownerHandle: cell.ownerHandle,
                      yours: cell.yours,
                    ).color.withValues(alpha: .48),
                    borderColor: Ownership.fromWire(
                      ownerHandle: cell.ownerHandle,
                      yours: cell.yours,
                    ).color,
                    borderStrokeWidth: 2.5,
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                Marker(
                  point: LatLng(DemoVenue.lat, DemoVenue.lng),
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
                      child: const Icon(Icons.my_location, color: RepRushTokens.brand),
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
          top: 76,
          child: _LeaderboardButton(),
        ),
      ],
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
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w800)),
      ]),
    ),
  );
}

class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.ownership, required this.count});
  final Ownership ownership;
  final int count;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(ownership.icon, color: ownership.color, size: 16),
    const SizedBox(width: 4),
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(ownership.label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
        Text('$count hexes', style: const TextStyle(fontSize: 9, color: Colors.white70)),
      ],
    ),
  ]);
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
