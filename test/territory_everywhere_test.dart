/// "Your territory, everywhere": every hex you hold is listed with its outline,
/// however far from the map, and the list agrees with the global board.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/app/app.dart';
import 'package:reprush/app/onboarding.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/demo/demo_repositories.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/live/live_repositories.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A live server whose grid is one unowned hex centred on whatever box is
/// asked for — enough for the demo to resolve its far-off hexes to "real"
/// cells.
class _GridServer implements TerritoryRepository {
  int gridReads = 0;

  @override
  Future<List<HexCell>> hexes({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
  }) async {
    gridReads++;
    final lat = (swLat + neLat) / 2;
    final lng = (swLng + neLng) / 2;
    const r = .002;
    return [
      HexCell(
        h3: 'real_${lat.toStringAsFixed(4)}_${lng.toStringAsFixed(4)}',
        polygon: [
          GeoPoint(lat: lat + r, lng: lng),
          GeoPoint(lat: lat + r / 2, lng: lng + r),
          GeoPoint(lat: lat - r / 2, lng: lng + r),
          GeoPoint(lat: lat - r, lng: lng),
          GeoPoint(lat: lat - r / 2, lng: lng - r),
          GeoPoint(lat: lat + r / 2, lng: lng - r),
        ],
        ownerColor: 'unclaimed',
        power: 0,
        yours: false,
      ),
    ];
  }

  @override
  Future<HexDetail> hexDetail(String h3) async => throw const ApiException(
    code: ApiErrorCode.unknownHex,
    message: 'none',
    statusCode: 404,
  );

  @override
  Future<List<LeaderboardRow>> leaderboard() async => const [];

  @override
  Future<List<HexCell>> myHexes() async => const [];
}

class _Transport implements ApiTransport {
  final calls = <String>[];

  @override
  Future<Object?> get(String function) async {
    calls.add(function);
    return [
      {
        'h3': '8842e44065fffff',
        'polygon': [
          for (var i = 0; i < 6; i++) {'lat': 24.87 + i / 1000, 'lng': 67.04},
        ],
        'ownerHandle': 'Blue Man',
        'ownerColor': 'mine',
        'power': 14.9,
        'yours': true,
      },
    ];
  }

  @override
  Future<Object?> getQuery(String function, Map<String, String> query) =>
      throw UnimplementedError();

  @override
  Future<Object?> post(String function, Map<String, Object?> body) =>
      throw UnimplementedError();
}

void main() {
  setUp(StubWorld.reset);

  test('live: one call to territory/mine, read as your hexes', () async {
    final transport = _Transport();
    final mine = await LiveTerritoryRepository(transport: transport).myHexes();
    expect(transport.calls, ['territory/mine']);
    expect(mine.single.yours, isTrue);
    expect(mine.single.polygon, hasLength(6));
  });

  test('offline demo: every hex of yours, the far ones kilometres out, and '
      'as many as the global board says', () async {
    final container = ProviderContainer(
      overrides: [
        backendConfigProvider.overrideWithValue(
          BackendConfig.parse(api: 'stub'),
        ),
      ],
    );
    addTearDown(container.dispose);

    final here = await container.read(territoryLocationProvider.future);
    final mine = await container.read(myHexesProvider.future);
    final board = await container.read(leaderboardProvider.future);

    expect(mine.every((c) => c.yours), isTrue);
    expect(mine.map((c) => c.h3).toSet(), hasLength(mine.length));
    final far = mine.where((c) {
      final centre = polygonCentre(c.polygon);
      return distanceM(here.lat, here.lng, centre.lat, centre.lng) > 3000;
    });
    expect(far, hasLength(StubWorld.yourSeedHexes));
    expect(
      board.firstWhere((r) => r.handle == 'demo_athlete').hexesHeld,
      mine.length,
    );
  });

  test('demo over a server: far hexes resolve to real cells, once', () async {
    final server = _GridServer();
    final demo = DemoTerritoryRepository(
      live: server,
      myHandle: () async => 'Me',
    );
    // Open the map around a point, as the app does.
    await demo.hexes(swLat: 24.85, swLng: 67.03, neLat: 24.89, neLng: 67.07);
    final reads = server.gridReads;

    final mine = await demo.myHexes();
    final far = mine.where((c) => c.h3.startsWith('real_') && c.yours);
    expect(far, hasLength(StubWorld.yourSeedHexes));
    expect(server.gridReads - reads, StubWorld.yourSeedHexes);

    // A second look costs nothing: they are resolved.
    await demo.myHexes();
    expect(server.gridReads - reads, StubWorld.yourSeedHexes);
  });

  testWidgets('tapping OWNED lists your territory', (tester) async {
    SharedPreferences.setMockInitialValues({
      OnboardingController.prefsKey: true,
    });
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.textContaining(' OWNED'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Your territory'), findsOneWidget);
    expect(find.textContaining('km away'), findsWidgets);
  });
}
