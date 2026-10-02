/// Demo over the real game — the repositories that make Demo mode look like
/// Live on a busy day, while keeping everything a demo does on this phone.
///
/// Ownership: B.
///
/// WHAT IS REAL AND WHAT IS NOT. With a server configured, Demo draws the REAL
/// hex grid around wherever you stand, and keeps every real owner on it. The
/// ground nobody really holds is then filled in with the demo's rivals (and a
/// few hexes of yours), so the map looks like a neighbourhood people are
/// actually fighting over — the same fixed pattern every launch. The board is
/// the same blend: the demo's rivals, you, and any real holders. Your sets are
/// scored on the phone and never submitted, the athletes nearby and their duels
/// are scripted, and the hexes your demo sets capture turn yours here and only
/// here (all in [StubWorld]). Nothing on the server, nobody else's map and no
/// real score ever changes.
library;

import 'dart:math' as math;

import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/models/models.dart';

/// Live territory, populated with the demo's rivals and your demo captures.
class DemoTerritoryRepository implements TerritoryRepository {
  const DemoTerritoryRepository({required this.live, required this.myHandle});

  final TerritoryRepository live;

  /// Your real handle, for your row on the demo board.
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
    // The map is fetched around you, so the centre cell is where you stand.
    final home = hexContaining(cells, (swLat + neLat) / 2, (swLng + neLng) / 2);
    if (home != null) StubWorld.claimHome(home.h3);
    return [for (final cell in cells) _dress(cell)];
  }

  HexCell _dress(HexCell cell) {
    if (StubWorld.isCaptured(cell.h3)) {
      return HexCell(
        h3: cell.h3,
        polygon: cell.polygon,
        ownerColor: 'mine',
        power: math.max(cell.power, StubWorld.powerOf(cell.h3)),
        yours: true,
      );
    }
    // Real ownership always shows as it is.
    if (cell.yours || cell.ownerHandle != null) return cell;
    final held = StubWorld.holder(cell.h3);
    return HexCell(
      h3: cell.h3,
      polygon: cell.polygon,
      ownerHandle: held.yours ? null : held.owner,
      ownerColor: held.yours
          ? 'mine'
          : held.owner == null
          ? 'unclaimed'
          : 'rival',
      power: held.owner == null ? 0 : StubWorld.powerOf(cell.h3),
      yours: held.yours,
    );
  }

  @override
  Future<HexDetail> hexDetail(String h3) async {
    HexDetail? real;
    try {
      real = await live.hexDetail(h3);
    } on ApiException catch (e) {
      // A hex nobody has ever really trained in has no record on the server.
      if (e.code != ApiErrorCode.unknownHex) rethrow;
    }
    final captured = StubWorld.isCaptured(h3);
    if (!captured && real?.ownerHandle != null) return real!;
    final handle = await myHandle();
    final held = captured ? (yours: true, owner: handle) : StubWorld.holder(h3);
    final owner = held.yours ? handle : held.owner;
    final power = math.max(real?.power ?? 0, StubWorld.powerOf(h3));
    final now = DateTime.now();
    return HexDetail(
      h3: h3,
      ownerHandle: owner,
      power: owner == null ? 0 : power,
      yourPower: held.yours ? power : 0,
      spots: real?.spots ?? const [],
      recentFlips: [
        if (owner != null)
          HexFlip(
            handle: owner,
            atMs: (captured ? now : now.subtract(const Duration(hours: 5)))
                .millisecondsSinceEpoch,
          ),
        ...?real?.recentFlips,
      ],
    );
  }

  @override
  Future<List<LeaderboardRow>> leaderboard() async {
    final real = await live.leaderboard();
    final handle = await myHandle();
    final counts = <String, int>{...StubWorld.rivalHexes};
    for (final row in real) {
      counts[row.handle] = (counts[row.handle] ?? 0) + row.hexesHeld;
    }
    counts[handle] =
        (counts[handle] ?? 0) + StubWorld.yourSeedHexes + StubWorld.newlyHeld;
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
