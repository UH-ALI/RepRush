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
    if (home != null) {
      StubWorld.claimHome(
        home.h3,
        at: GeoPoint(lat: (swLat + neLat) / 2, lng: (swLng + neLng) / 2),
      );
    }
    final dressed = [for (final cell in cells) _dress(cell)];
    StubWorld.recordView(dressed);
    return dressed;
  }

  HexCell _dress(HexCell cell) {
    if (StubWorld.isCaptured(cell.h3)) {
      return HexCell(
        h3: cell.h3,
        polygon: cell.polygon,
        ownerColor: 'mine',
        power: StubWorld.yourPowerIn(cell.h3),
        yours: true,
      );
    }
    // Real ownership always shows as it is.
    if (cell.yours || cell.ownerHandle != null) return cell;
    final held = StubWorld.holder(cell.h3, at: polygonCentre(cell.polygon));
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
    if (!captured && real?.ownerHandle != null) {
      // A real holder: their real power, plus whatever your demo sets added.
      return HexDetail(
        h3: h3,
        ownerHandle: real!.ownerHandle,
        power: real.power,
        yourPower: real.yourPower + StubWorld.yourPowerIn(h3),
        spots: real.spots,
        recentFlips: real.recentFlips,
      );
    }
    final handle = await myHandle();
    final held = captured ? (yours: true, owner: handle) : StubWorld.holder(h3);
    final owner = held.yours ? handle : held.owner;
    final power = captured
        ? StubWorld.yourPowerIn(h3)
        : math.max(real?.power ?? 0, StubWorld.powerOf(h3));
    final now = DateTime.now();
    return HexDetail(
      h3: h3,
      ownerHandle: owner,
      power: owner == null ? 0 : power,
      yourPower: held.yours ? power : StubWorld.yourPowerIn(h3),
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

  /// Your real hexes, plus the demo's: those drawn so far, and the ones
  /// beyond the map — each resolved once to the REAL cell at its place by a
  /// small grid read there, so flying to it lands on a real hex.
  @override
  Future<List<HexCell>> myHexes() async {
    for (final (index, point) in StubWorld.unresolvedElsewhere()) {
      for (final pad in const [.006, .012]) {
        final cells = await live.hexes(
          swLat: point.lat - pad,
          swLng: point.lng - pad,
          neLat: point.lat + pad,
          neLng: point.lng + pad,
        );
        final cell = StubWorld.cellFor(cells, point);
        if (cell != null) {
          StubWorld.addElsewhere(index, cell);
          break;
        }
      }
    }
    var real = const <HexCell>[];
    try {
      real = await live.myHexes();
    } on ApiException {
      // A server without the route yet: the demo's hexes are still listed.
    }
    return {
      for (final cell in real) cell.h3: cell,
      for (final cell in StubWorld.myHexes) cell.h3: cell,
    }.values.toList();
  }

  /// The real history where the hex has one; otherwise the demo's — your
  /// demo sets always on top.
  @override
  Future<List<HexActivity>> hexHistory(String h3) async {
    var real = const <HexActivity>[];
    try {
      real = await live.hexHistory(h3);
    } on ApiException {
      // A server without the route yet.
    }
    final demo = StubWorld.history(h3, you: await myHandle());
    if (real.isEmpty) return demo;
    return [...demo.where((a) => a.yours && a.atMs > real.first.atMs), ...real];
  }

  @override
  Future<List<LeaderboardRow>> leaderboard() async {
    final real = await live.leaderboard();
    final handle = await myHandle();
    final counts = StubWorld.globalCounts(handle);
    // A real holder's real count already includes their hexes on your map.
    for (final row in real) {
      if (row.handle == handle) continue;
      counts[row.handle] = math.max(counts[row.handle] ?? 0, row.hexesHeld);
    }
    return LeaderboardRow.rankCounts(counts, you: handle);
  }
}
