/// Territory map screen placeholder (requirements.md D1).
///
/// Real hex rendering lands with C-4 (`flutter_map` + server-computed H3
/// polygons, B-10). This placeholder proves the provider wiring end to end
/// and shows the accessible ownership legend (N9: colour + label + icon).
///
/// Ownership: C (ui).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
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

class _MapView extends StatelessWidget {
  const _MapView({required this.cells});

  final List<HexCell> cells;

  @override
  Widget build(BuildContext context) {
    final yours = cells.where((c) => c.yours).length;
    final rivals = cells.where((c) => !c.yours && c.ownerHandle != null).length;
    final open = cells.length - yours - rivals;
    return ListView(
      padding: const EdgeInsets.all(RepRushTokens.spaceMd),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Your territory', style: RepRushTokens.displayLarge.copyWith(fontSize: 28)),
            Chip(label: Text('$yours hexes'), avatar: const Icon(Icons.hexagon, size: 16, color: RepRushTokens.brand)),
          ],
        ),
        const SizedBox(height: RepRushTokens.spaceMd),
        _legendRow(context, Ownership.yours, yours),
        _legendRow(context, Ownership.rival, rivals),
        _legendRow(context, Ownership.unclaimed, open),
        const SizedBox(height: RepRushTokens.spaceSm),
        GlassCard(
          padding: EdgeInsets.zero,
          child: SizedBox(
            height: 310,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
              child: CustomPaint(painter: _HexGridPainter(cells)),
            ),
          ),
        ),
        const SizedBox(height: RepRushTokens.spaceMd),
        const SizedBox(height: RepRushTokens.spaceLg),
        Text('Top holders', style: RepRushTokens.sectionTitle),
        const _LeaderboardList(),
      ],
    );
  }

  Widget _legendRow(BuildContext context, Ownership ownership, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RepRushTokens.spaceXs),
      child: Row(
        children: [
          Icon(ownership.icon, color: ownership.color),
          const SizedBox(width: RepRushTokens.spaceSm),
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              color: ownership.color,
              borderRadius: BorderRadius.circular(RepRushTokens.cornerChip / 2),
            ),
          ),
          const SizedBox(width: RepRushTokens.spaceSm),
          Expanded(child: Text(ownership.label)),
          Text('$count hexes'),
        ],
      ),
    );
  }

}

class _HexGridPainter extends CustomPainter {
  _HexGridPainter(this.cells);
  final List<HexCell> cells;

  @override
  void paint(Canvas canvas, Size size) {
    if (cells.isEmpty) return;
    final points = cells.expand((c) => c.polygon).toList();
    final minLat = points.map((p) => p.lat).reduce(math.min);
    final maxLat = points.map((p) => p.lat).reduce(math.max);
    final minLng = points.map((p) => p.lng).reduce(math.min);
    final maxLng = points.map((p) => p.lng).reduce(math.max);
    final latSpan = (maxLat - minLat).abs().clamp(.000001, double.infinity);
    final lngSpan = (maxLng - minLng).abs().clamp(.000001, double.infinity);
    for (final cell in cells) {
      final path = Path();
      for (var i = 0; i < cell.polygon.length; i++) {
        final point = cell.polygon[i];
        final x = (point.lng - minLng) / lngSpan * size.width;
        final y = size.height - (point.lat - minLat) / latSpan * size.height;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      path.close();
      final ownership = Ownership.fromWire(ownerHandle: cell.ownerHandle, yours: cell.yours);
      canvas.drawPath(path, Paint()..color = ownership.color.withValues(alpha: .52));
      canvas.drawPath(path, Paint()
        ..color = ownership.color.withValues(alpha: .85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(covariant _HexGridPainter oldDelegate) => oldDelegate.cells != cells;
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
