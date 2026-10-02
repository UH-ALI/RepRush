/// The in-app Live/Demo switch, and the live presence/duels repositories'
/// wire handling.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/app/app.dart';
import 'package:reprush/app/onboarding.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/live/live_repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

ProviderContainer _container({required BackendConfig config, ApiMode? saved}) {
  final container = ProviderContainer(
    overrides: [
      backendConfigProvider.overrideWithValue(config),
      savedApiModeProvider.overrideWithValue(saved),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

final _keyed = BackendConfig.parse(api: 'stub', anonKey: 'test-key');
final _keyless = BackendConfig.parse(api: 'stub');

class _Transport implements ApiTransport {
  _Transport(this.reply);

  final Object? Function(String verb, String function) reply;
  final calls = <String>[];
  final bodies = <Map<String, Object?>>[];

  @override
  Future<Object?> get(String function) async {
    calls.add('GET $function');
    return reply('GET', function);
  }

  @override
  Future<Object?> getQuery(String function, Map<String, String> query) async {
    calls.add('GET $function');
    return reply('GET', function);
  }

  @override
  Future<Object?> post(String function, Map<String, Object?> body) async {
    calls.add('POST $function');
    bodies.add(body);
    return reply('POST', function);
  }
}

const _duelJson = <String, Object?>{
  'id': '3f1c2d4e-0000-4000-8000-000000000001',
  'movementId': 'squat',
  'opponentId': 'b0b00000-0000-4000-8000-000000000002',
  'opponentHandle': 'Bilal',
  'incoming': true,
  'status': 'finished',
  'respondByMs': 1760000300000,
  'endsAtMs': 1760000900000,
  'myReps': 20,
  'theirReps': 12,
  'result': 'won',
  'xpReward': 100,
  'claimed': false,
};

void main() {
  group('app mode', () {
    test('opens in the build default with nothing saved', () {
      final c = _container(config: _keyed);
      expect(c.read(appModeProvider), ApiMode.stub);
      expect(c.read(isLiveProvider), isFalse);
      expect(c.read(apiTransportProvider), isNull);
      expect(c.read(presenceRepositoryProvider), isA<StubPresenceRepository>());
      expect(c.read(duelsRepositoryProvider), isA<StubDuelsRepository>());
    });

    test('a saved choice wins over the build default', () {
      final c = _container(config: _keyed, saved: ApiMode.live);
      expect(c.read(isLiveProvider), isTrue);
    });

    test('a saved Live falls back to the demo in a build with no key', () {
      final c = _container(config: _keyless, saved: ApiMode.live);
      expect(c.read(appModeProvider), ApiMode.stub);
    });

    test('switching to Live rebinds every repository to the server', () async {
      SharedPreferences.setMockInitialValues({});
      final c = _container(config: _keyed);
      await c.read(appModeProvider.notifier).select(ApiMode.live);

      expect(c.read(isLiveProvider), isTrue);
      expect(c.read(apiTransportProvider), isNotNull);
      expect(c.read(presenceRepositoryProvider), isA<LivePresenceRepository>());
      expect(c.read(duelsRepositoryProvider), isA<LiveDuelsRepository>());
      expect(
        c.read(territoryRepositoryProvider),
        isA<LiveTerritoryRepository>(),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AppModeController.prefsKey), 'live');
    });

    test('Live cannot be chosen in a build with no key', () async {
      SharedPreferences.setMockInitialValues({});
      final c = _container(config: _keyless);
      await c.read(appModeProvider.notifier).select(ApiMode.live);
      expect(c.read(appModeProvider), ApiMode.stub);
    });
  });

  group('live presence', () {
    test('heartbeat posts the fix and reads players by hex centre', () async {
      final transport = _Transport(
        (verb, function) => [
          {
            'userId': 'b0b00000-0000-4000-8000-000000000002',
            'handle': 'Bilal',
            'level': 3,
            'hexesHeld': 2,
            'h3': '88195da49bfffff',
            'centre': {'lat': 51.5079, 'lng': -0.1281},
          },
        ],
      );
      final players = await LivePresenceRepository(
        transport: transport,
      ).heartbeat(const SessionLocation(lat: 51.5, lng: -0.12, accuracyM: 9));

      expect(transport.calls, ['POST presence']);
      expect(transport.bodies.single['location'], {
        'lat': 51.5,
        'lng': -0.12,
        'accuracyM': 9.0,
        'isMocked': false,
      });
      expect(players.single.handle, 'Bilal');
      expect(players.single.centre.lat, 51.5079);
    });

    test('going hidden posts to presence/off', () async {
      final transport = _Transport((_, _) => {'visible': false});
      await LivePresenceRepository(transport: transport).goInvisible();
      expect(transport.calls, ['POST presence/off']);
    });
  });

  group('live duels', () {
    test('every route reaches the duels function by path', () async {
      final transport = _Transport(
        (verb, function) => function == 'duels' && verb == 'GET'
            ? [_duelJson]
            : function.endsWith('/claim')
            ? {'claimed': true, 'xpAwarded': 100}
            : _duelJson,
      );
      final repo = LiveDuelsRepository(transport: transport);
      final list = await repo.list();
      await repo.challenge(opponentId: 'x', movementId: 'squat');
      await repo.respond('d1', accept: true);
      await repo.respond('d1', accept: false);
      final claim = await repo.claim('d1');

      expect(transport.calls, [
        'GET duels',
        'POST duels',
        'POST duels/d1/accept',
        'POST duels/d1/decline',
        'POST duels/d1/claim',
      ]);
      expect(transport.bodies[0], {'opponentId': 'x', 'movementId': 'squat'});
      expect(list.single.status, DuelStatus.finished);
      expect(list.single.canClaim, isTrue);
      expect(claim.xpAwarded, 100);
    });

    test('a duel with nothing posted yet parses its nulls', () {
      final pending = Duel.fromJson({
        ..._duelJson,
        'status': 'pending',
        'endsAtMs': null,
        'myReps': null,
        'theirReps': null,
        'result': null,
        'xpReward': 0,
      });
      expect(pending.open, isTrue);
      expect(pending.myReps, isNull);
      expect(pending.canClaim, isFalse);
    });
  });

  testWidgets('Profile offers Demo, and Live only with a server', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      OnboardingController.prefsKey: true,
    });
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // The map says it is the demo.
    expect(find.text('DEMO'), findsOneWidget);

    await tester.tap(find.text('Profile'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.scrollUntilVisible(
      find.text('Game world'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Game world'), findsOneWidget);
    expect(find.textContaining("isn't connected to a server"), findsOneWidget);
  });
}
