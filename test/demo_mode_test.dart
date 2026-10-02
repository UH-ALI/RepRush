/// Demo over the real game: captures are painted on the live map and board
/// without touching the server, and a demo set is scored on the phone.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/core/api/demo/demo_repositories.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
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

  test('before any demo set, the demo map IS the live map', () async {
    final cells = await map();
    expect(
      cells.firstWhere((c) => c.h3 == 'rival_hex').ownerHandle,
      'Blue Man',
    );
    expect(cells.where((c) => c.yours).map((c) => c.h3), ['mine_hex']);
    expect((await demo.leaderboard()).single.handle, 'Blue Man');
  });

  test('a demo set in a rival hex captures it — on this phone only', () async {
    StubWorld.beginSession('rival_hex', wasYours: false);
    final result = await const StubSessionRepository().submit(
      _set('squat', 14),
    );
    expect(result.hexResult?.h3, 'rival_hex');
    expect(result.hexResult?.captured, isTrue);

    final cells = await map();
    final taken = cells.firstWhere((c) => c.h3 == 'rival_hex');
    expect(taken.yours, isTrue);
    expect(taken.ownerColor, 'mine');

    // You overtake Blue Man on the board.
    final board = await demo.leaderboard();
    expect(board.first.handle, 'Me');
    expect(board.first.hexesHeld, 1);
    expect(board.first.rank, 1);
    expect(board[1].handle, 'Blue Man');
  });

  test('a set in a hex you already hold adds power, not a capture', () async {
    StubWorld.beginSession('mine_hex', wasYours: true);
    final result = await const StubSessionRepository().submit(
      _set('squat', 10),
    );
    expect(result.hexResult?.captured, isFalse);
    // Nothing new held, so the board is untouched.
    expect((await demo.leaderboard()).single.handle, 'Blue Man');
  });

  test('the demo score comes from the set you did', () async {
    StubWorld.beginSession('open_hex', wasYours: false);
    final squats = await const StubSessionRepository().submit(
      _set('squat', 12),
    );
    final pullUps = await const StubSessionRepository().submit(
      _set('pull_up', 12),
    );
    expect(squats.xp, greaterThan(0));
    expect(pullUps.xp, greaterThan(squats.xp));
    expect(squats.spotResult, isNull);
    // The first 12-rep pull-up set is a PR; the capture only happens once.
    expect(pullUps.prs.single.value, 12);
    expect(squats.hexResult?.captured, isTrue);
    expect(pullUps.hexResult?.captured, isFalse);
  });

  test('a captured hex with no server record still opens its detail', () async {
    StubWorld.beginSession('open_hex', wasYours: false);
    await const StubSessionRepository().submit(_set('squat', 8));
    final detail = await demo.hexDetail('open_hex');
    expect(detail.ownerHandle, 'Me');
    expect(detail.recentFlips.first.handle, 'Me');
  });
}
