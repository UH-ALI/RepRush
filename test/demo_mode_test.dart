/// Demo over the real game: captures are painted on the live map and board
/// without touching the server, and a demo set is scored on the phone.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/demo/demo_repositories.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';

HexCell _cell(String h3, {String? owner, bool yours = false}) => HexCell(
  h3: h3,
  polygon: const [GeoPoint(lat: 0, lng: 0)],
  ownerHandle: owner,
  ownerColor: yours
      ? 'mine'
      : owner == null
      ? 'unclaimed'
      : 'rival',
  power: owner == null ? 0 : 15,
  yours: yours,
);

/// The live server as the demo sees it: Blue Man holds one hex.
class _LiveTerritory implements TerritoryRepository {
  @override
  Future<List<HexCell>> hexes({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
  }) async => [
    _cell('rival_hex', owner: 'Blue Man'),
    _cell('open_hex'),
    _cell('mine_hex', owner: 'Me', yours: true),
  ];

  @override
  Future<HexDetail> hexDetail(String h3) async => throw const ApiException(
    code: ApiErrorCode.unknownHex,
    message: 'none',
    statusCode: 404,
  );

  @override
  Future<List<HexActivity>> hexHistory(String h3) async => const [];

  @override
  Future<List<HexCell>> myHexes() async => [
    _cell('mine_hex', owner: 'Me', yours: true),
  ];

  @override
  Future<List<LeaderboardRow>> leaderboard() async => const [
    LeaderboardRow(rank: 1, handle: 'Blue Man', hexesHeld: 1, areaKm2: .7),
  ];
}

Map<String, Object?> _set(String movementId, int reps) => {
  'sets': [
    {
      'movementId': movementId,
      'reps': [for (var i = 0; i < reps; i++) <String, Object?>{}],
    },
  ],
};

void main() {
  setUp(StubWorld.reset);

  final demo = DemoTerritoryRepository(
    live: _LiveTerritory(),
    myHandle: () async => 'Me',
  );

  Future<List<HexCell>> map() =>
      demo.hexes(swLat: 0, swLng: 0, neLat: 1, neLng: 1);

  test('real owners stay; open ground fills with the demo rivals', () async {
    final cells = await map();
    final rival = cells.firstWhere((c) => c.h3 == 'rival_hex');
    expect(rival.ownerHandle, 'Blue Man');
    expect(cells.firstWhere((c) => c.h3 == 'mine_hex').yours, isTrue);

    // Ground nobody really holds gets the fixed demo pattern.
    final open = cells.firstWhere((c) => c.h3 == 'open_hex');
    final expected = StubWorld.holder('open_hex');
    expect(open.yours, expected.yours);
    if (!expected.yours) expect(open.ownerHandle, expected.owner);
    // …and the same pattern every time.
    expect(
      (await map()).firstWhere((c) => c.h3 == 'open_hex').ownerHandle,
      open.ownerHandle,
    );
  });

  test('the global board is busy: your map plus everyone elsewhere', () async {
    final yoursOnMap = (await map()).where((c) => c.yours).length;
    final board = await demo.leaderboard();
    final handles = board.map((r) => r.handle).toList();
    expect(handles, containsAll(['iron_meridian', 'rival_kat', 'Blue Man']));
    expect(
      board.firstWhere((r) => r.handle == 'Me').hexesHeld,
      StubWorld.yourSeedHexes + yoursOnMap,
    );
    // A real holder keeps their real count.
    expect(board.firstWhere((r) => r.handle == 'Blue Man').hexesHeld, 1);
    expect(
      [for (final r in board) r.rank],
      [for (var i = 1; i <= board.length; i++) i],
    );
  });

  test('a set that out-powers the holder captures — on this phone', () async {
    // Blue Man holds it with 15; 20 squats ≈ 18 power.
    StubWorld.beginSession('rival_hex', wasYours: false, holderPower: 15);
    final result = await const StubSessionRepository().submit(
      _set('squat', 20),
    );
    expect(result.hexResult?.h3, 'rival_hex');
    expect(result.hexResult?.captured, isTrue);
    expect(result.hexResult?.yourPower, closeTo(18, .01));

    final cells = await map();
    final taken = cells.firstWhere((c) => c.h3 == 'rival_hex');
    expect(taken.yours, isTrue);
    expect(taken.ownerColor, 'mine');
    // The global board follows the map.
    expect(
      (await demo.leaderboard()).firstWhere((r) => r.handle == 'Me').hexesHeld,
      StubWorld.yourSeedHexes + cells.where((c) => c.yours).length,
    );
  });

  test('a set short of the holder adds power but does not capture', () async {
    StubWorld.beginSession('rival_hex', wasYours: false, holderPower: 40);
    final first = await const StubSessionRepository().submit(_set('squat', 20));
    expect(first.hexResult?.captured, isFalse);
    expect(first.hexResult?.power, 40);
    expect(first.hexResult?.yourPower, closeTo(18, .01));
    expect((await map()).firstWhere((c) => c.h3 == 'rival_hex').yours, isFalse);
    // The progress shows up in the hex detail…
    expect((await demo.hexDetail('rival_hex')).yourPower, closeTo(18, .01));

    // …and power accumulates: two more sets pass 40.
    await const StubSessionRepository().submit(_set('squat', 20));
    final third = await const StubSessionRepository().submit(_set('squat', 20));
    expect(third.hexResult?.captured, isTrue);
    expect(third.hexResult?.yourPower, closeTo(54, .01));
  });

  test('a set below the claim floor earns XP but no territory', () async {
    StubWorld.beginSession('open_hex', wasYours: false, holderPower: 0);
    final result = await const StubSessionRepository().submit(_set('squat', 5));
    expect(result.xp, greaterThan(0));
    expect(result.hexResult, isNull);
  });

  test('a set in a hex you already hold keeps it, with more power', () async {
    StubWorld.beginSession('mine_hex', wasYours: true, holderPower: 15);
    final result = await const StubSessionRepository().submit(
      _set('squat', 12),
    );
    expect(result.hexResult?.captured, isTrue);
    expect(result.hexResult?.yourPower, closeTo(25.8, .01));
  });

  test('the demo score comes from the set you did', () async {
    StubWorld.beginSession('open_hex', wasYours: false, holderPower: 0);
    final squats = await const StubSessionRepository().submit(
      _set('squat', 12),
    );
    final pullUps = await const StubSessionRepository().submit(
      _set('pull_up', 12),
    );
    // reps × difficulty × 0.9, as the server would roughly score them.
    expect(squats.xp, 11);
    expect(pullUps.xp, 19);
    expect(squats.spotResult, isNull);
    expect(pullUps.prs.single.value, 12);
    // 10.8 claims the open hex.
    expect(squats.hexResult?.captured, isTrue);
  });

  test('a captured hex with no server record still opens its detail', () async {
    StubWorld.beginSession('open_hex', wasYours: false, holderPower: 0);
    await const StubSessionRepository().submit(_set('squat', 15));
    final detail = await demo.hexDetail('open_hex');
    expect(detail.ownerHandle, 'Me');
    expect(detail.recentFlips.first.handle, 'Me');
  });

  test("the hex you open the map in is a rival's, and one set takes it", () {
    StubWorld.claimHome('home_hex');
    final held = StubWorld.holder('home_hex');
    expect(held.yours, isFalse);
    expect(held.owner, isNotNull);
    // One honest set of ~15 squats (13.5 power) passes it.
    expect(StubWorld.powerOf('home_hex'), lessThan(13.5));
  });

  test('nearby board counts the map; global is never smaller', () async {
    final container = ProviderContainer(
      overrides: [
        backendConfigProvider.overrideWithValue(
          BackendConfig.parse(api: 'stub'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final cells = await container.read(hexesProvider.future);
    final nearby = await container.read(nearbyLeaderboardProvider.future);
    final global = await container.read(leaderboardProvider.future);

    // Nearby is exactly who holds what on the map.
    expect(
      nearby.fold<int>(0, (sum, r) => sum + r.hexesHeld),
      cells.where((c) => c.yours || c.ownerHandle != null).length,
    );
    for (final row in nearby) {
      final everywhere = global.firstWhere((g) => g.handle == row.handle);
      expect(everywhere.hexesHeld, greaterThanOrEqualTo(row.hexesHeld));
    }
  });
}
