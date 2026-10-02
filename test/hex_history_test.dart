/// Hex history: the live route's wire shape, the demo's history, and the
/// list in the hex sheet.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/app/app.dart';
import 'package:reprush/app/onboarding.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/live/live_repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Transport implements ApiTransport {
  final calls = <String>[];

  @override
  Future<Object?> get(String function) async {
    calls.add(function);
    return [
      {
        'handle': 'Blue Man',
        'movementId': 'squat',
        'reps': 18,
        'holdSeconds': null,
        'power': 16.2,
        'atMs': 1790000000000,
        'yours': false,
      },
      {
        'handle': 'Me',
        'movementId': 'push_up',
        'reps': 6,
        'holdSeconds': null,
        'power': null,
        'atMs': 1789990000000,
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

HexCell _cell(
  String h3, {
  String? owner,
  bool yours = false,
  double power = 0,
}) => HexCell(
  h3: h3,
  polygon: const [GeoPoint(lat: 0, lng: 0)],
  ownerHandle: owner,
  ownerColor: yours
      ? 'mine'
      : owner == null
      ? 'unclaimed'
      : 'rival',
  power: power,
  yours: yours,
);

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

  test(
    'live: one call per hex, and a set below the floor has no power',
    () async {
      final transport = _Transport();
      final history = await LiveTerritoryRepository(
        transport: transport,
      ).hexHistory('8842e44065fffff');
      expect(transport.calls, ['territory/history/8842e44065fffff']);
      expect(history.first.handle, 'Blue Man');
      expect(history.first.power, 16.2);
      expect(history.last.yours, isTrue);
      expect(history.last.power, isNull);
      expect(
        HexActivity.fromJson(history.first.toJson()).toJson(),
        history.first.toJson(),
      );
    },
  );

  test("demo: a rival's hex has a past that earned its power", () {
    StubWorld.recordView([_cell('kat_hex', owner: 'rival_kat', power: 40)]);
    final past = StubWorld.history('kat_hex', you: 'Me');
    final holders = past.where((a) => a.handle == 'rival_kat');
    expect(holders, isNotEmpty);
    expect(
      holders.fold<double>(0, (sum, a) => sum + a.power!),
      closeTo(40, .5),
    );
    // Every set that counted cleared the claim floor.
    expect(past.every((a) => a.power! >= StubWorld.minClaimPower), isTrue);
    // Newest first.
    for (var i = 1; i < past.length; i++) {
      expect(past[i - 1].atMs, greaterThanOrEqualTo(past[i].atMs));
    }
  });

  test('demo: open ground has no past; your demo sets go on top', () async {
    StubWorld.recordView([_cell('open_hex')]);
    expect(StubWorld.history('open_hex', you: 'Me'), isEmpty);

    StubWorld.beginSession('open_hex', wasYours: false, holderPower: 0);
    await const StubSessionRepository().submit(_set('squat', 6)); // below floor
    await const StubSessionRepository().submit(_set('squat', 15));
    final history = StubWorld.history('open_hex', you: 'Me');
    expect(history, hasLength(2));
    expect(history.first.reps, 15);
    expect(history.first.power, closeTo(13.5, .01));
    expect(history.first.yours, isTrue);
    expect(history.last.power, isNull);
  });

  testWidgets('the hex sheet shows recent activity', (tester) async {
    SharedPreferences.setMockInitialValues({
      OnboardingController.prefsKey: true,
    });
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The pill naming the hex you are in opens its sheet.
    await tester.tap(find.textContaining(RegExp(r'^IN .* HEX$')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Recent activity'), findsOneWidget);
    // The hex you open in is always a rival's, with a past.
    expect(find.textContaining(' ago'), findsWidgets);
  });
}
