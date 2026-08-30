/// Territory map screen placeholder (requirements.md D1).
///
/// Real hex rendering lands with C-4 (`flutter_map` + server-computed H3
/// polygons, B-10). This placeholder proves the provider wiring end to end
/// and shows the accessible ownership legend (N9: colour + label + icon).
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/states/states.dart';

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
        data: (cells) => _MapPlaceholder(cells: cells),
      ),
    );
  }
}

class _MapPlaceholder extends StatelessWidget {
  const _MapPlaceholder({required this.cells});

  final List<HexCell> cells;

  @override
  Widget build(BuildContext context) {
    final yours = cells.where((c) => c.yours).length;
    final rivals = cells.where((c) => !c.yours && c.ownerHandle != null).length;
    final open = cells.length - yours - rivals;
    return ListView(
      padding: const EdgeInsets.all(RepRushTokens.spaceMd),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(RepRushTokens.spaceMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hex map placeholder',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: RepRushTokens.spaceXs),
                Text(
                  'flutter_map renders ${cells.length} H3 res-8 hexes here '
                  '(C-4). Polygons are computed server-side — no H3 on the '
                  'client (§8 open-1).',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: RepRushTokens.spaceMd),
        _legendRow(context, Ownership.yours, yours),
        _legendRow(context, Ownership.rival, rivals),
        _legendRow(context, Ownership.unclaimed, open),
        const SizedBox(height: RepRushTokens.spaceLg),
        Text('Top holders', style: Theme.of(context).textTheme.titleMedium),
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
