/// Demo over the real game — the repositories that make Demo mode look exactly
/// like Live while keeping every demo result on this phone.
///
/// Ownership: B.
///
/// WHAT IS REAL AND WHAT IS NOT. With a server configured, Demo reads the real
/// map, real owners, the real leaderboard, your real profile and the real daily
/// challenge. Three things are simulated: a set's score (the stub session
/// repository scores it locally and never submits), the athletes nearby (the
/// scripted rivals) and the hexes your demo sets capture. Those captures live
/// in [StubWorld] and are painted over the real territory here, so the map,
/// the hex count and the leaderboard all react to a demo set — and nothing on
/// the server, nobody else's map and no real score ever changes.
library;

import 'dart:math' as math;

import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/models/models.dart';

/// Live territory with the demo's captures painted on top.
class DemoTerritoryRepository implements TerritoryRepository {
  const DemoTerritoryRepository({required this.live, required this.myHandle});

  final TerritoryRepository live;

  /// Your real handle, for the leaderboard row the demo adds to.
  final Future<String> Function() myHandle;

  @override
  Future<List<HexCell>> hexes({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
  }) async {
    final cells = await live.hexes(
      swLat: swLat,
      swLng: swLng,
      neLat: neLat,
      neLng: neLng,
    );
    return [
      for (final cell in cells)
        StubWorld.isCaptured(cell.h3) && !cell.yours
            ? HexCell(
                h3: cell.h3,
                polygon: cell.polygon,
                ownerColor: 'mine',
                power: math.max(cell.power, 1),
                yours: true,
              )
            : cell,
    ];
  }

  @override
  Future<HexDetail> hexDetail(String h3) async {
    if (!StubWorld.isCaptured(h3)) return live.hexDetail(h3);
    final handle = await myHandle();
    HexDetail? real;
    try {
      real = await live.hexDetail(h3);
    } on ApiException catch (e) {
      // A hex nobody has ever trained in has no record on the server.
      if (e.code != ApiErrorCode.unknownHex) rethrow;
    }
    final power = math.max(real?.power ?? 0, 1).toDouble();
    return HexDetail(
      h3: h3,
      ownerHandle: handle,
      power: power,
      yourPower: power,
      spots: real?.spots ?? const [],
      recentFlips: [
        HexFlip(handle: handle, atMs: DateTime.now().millisecondsSinceEpoch),
        ...?real?.recentFlips,
      ],
    );
  }

  @override
  Future<List<LeaderboardRow>> leaderboard() async {
    final rows = await live.leaderboard();
    final extra = StubWorld.newlyHeld;
    if (extra == 0) return rows;
    final handle = await myHandle();
    final counts = <String, int>{
      for (final row in rows) row.handle: row.hexesHeld,
    };
    counts[handle] = (counts[handle] ?? 0) + extra;
    // On a tie you rank first: you are the one who just took ground.
    final ranked = counts.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key == handle
            ? -1
            : b.key == handle
            ? 1
            : 0;
      });
    return [
      for (var i = 0; i < ranked.length; i++)
        LeaderboardRow(
          rank: i + 1,
          handle: ranked[i].key,
          hexesHeld: ranked[i].value,
          // Res-8 cells average ~0.74 km², the figure the server uses.
          areaKm2: ranked[i].value * 0.737,
        ),
    ];
  }
}
