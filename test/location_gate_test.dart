/// The location rules: a session can only be started for the hex the athlete
/// is standing in, the "current hex" is resolved from the polygons the server
/// sent, and a scored set refreshes every screen that shows its consequences.
///
/// Runs in stub mode, where every location provider is pinned to the demo
/// venue — so the venue is "here" and the gate is deterministic.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/core/location/location.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/errors.dart';

/// A square "hex" centred on ([lat], [lng]) — the gate only needs a polygon.
HexCell _cell(String h3, double lat, double lng, {double half = .002}) =>
    HexCell(
      h3: h3,
      polygon: [
        GeoPoint(lat: lat - half, lng: lng - half),
        GeoPoint(lat: lat + half, lng: lng - half),
        GeoPoint(lat: lat + half, lng: lng + half),
        GeoPoint(lat: lat - half, lng: lng + half),
      ],
      ownerColor: 'unclaimed',
      power: 0,
      yours: false,
    );

final _here = _cell('here', DemoVenue.lat, DemoVenue.lng);
// ~1.1 km north of the venue.
final _faraway = _cell('faraway', DemoVenue.lat + .01, DemoVenue.lng);

class _CountingProgression implements ProgressionRepository {
  int meCalls = 0;

  @override
  Future<UserProfile> me() {
    meCalls++;
    return const StubProgressionRepository().me();
  }

  @override
  Future<List<Movement>> movements() =>
      const StubProgressionRepository().movements();
}

ProviderContainer _container({List<Override> extra = const []}) {
  final container = ProviderContainer(
    overrides: [
      backendConfigProvider.overrideWithValue(BackendConfig.parse(api: 'stub')),
      hexesProvider.overrideWith((ref) async => [_here, _faraway]),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('geometry', () {
    test('a point inside the polygon is inside; one outside is not', () {
      expect(polygonContains(_here.polygon, DemoVenue.lat, DemoVenue.lng), isTrue);
      expect(
        polygonContains(_here.polygon, DemoVenue.lat + .01, DemoVenue.lng),
        isFalse,
      );
    });

    test('hexContaining picks the right cell, or none', () {
      final cells = [_here, _faraway];
      expect(hexContaining(cells, DemoVenue.lat, DemoVenue.lng)?.h3, 'here');
      expect(
        hexContaining(cells, DemoVenue.lat + .01, DemoVenue.lng)?.h3,
        'faraway',
      );
      expect(hexContaining(cells, 0, 0), isNull);
    });

    test('distance and its copy', () {
      // 0.01° of latitude is ~1.11 km anywhere on Earth.
      final d = distanceM(DemoVenue.lat, DemoVenue.lng, DemoVenue.lat + .01, DemoVenue.lng);
      expect(d, closeTo(1112, 5));
      expect(formatDistance(d), '1.1 km');
      expect(formatDistance(347), '350 m');
    });
  });

  group('current hex', () {
    test('resolves to the cell containing the athlete', () async {
      final container = _container();
      // Subscribed like the map is: Riverpod 3 pauses unlistened providers, so
      // a bare read of the location stream would never see it emit.
      container.listen(currentHexProvider, (_, _) {});
      await container.read(hexesProvider.future);
      await container.read(currentLocationProvider.future);
      expect(container.read(currentHexProvider)?.h3, 'here');
    });
  });

  group('startHere — the one way a session opens', () {
    test('refuses a hex the athlete is not standing in, naming the distance', () async {
      final container = _container();

      await expectLater(
        container
            .read(activeSessionProvider.notifier)
            .startHere(targetH3: 'faraway'),
        throwsA(
          isA<TrainingBlocked>().having(
            (e) => e.message,
            'message',
            allOf(contains('1.1 km'), contains('Walk into it')),
          ),
        ),
      );
      // Refused BEFORE the server call: no session was opened.
      expect(container.read(activeSessionProvider), isNull);
    });

    test('opens a session for the hex the athlete is in', () async {
      final container = _container();

      final session = await container
          .read(activeSessionProvider.notifier)
          .startHere(targetH3: 'here');

      expect(container.read(activeSessionProvider), same(session));
      expect(
        container.read(activeSessionProvider.notifier).startLocation,
        demoVenueLocation,
      );
    });

    test('without a target it starts wherever the athlete is', () async {
      final container = _container();
      await container.read(activeSessionProvider.notifier).startHere();
      expect(container.read(activeSessionProvider), isNotNull);
    });

    test('abandon forgets the session without submitting', () async {
      final container = _container();
      final notifier = container.read(activeSessionProvider.notifier);
      await notifier.startHere();
      notifier.abandon();
      expect(container.read(activeSessionProvider), isNull);
      expect(notifier.startLocation, isNull);
    });
  });

  group('submit refreshes the consequences', () {
    test('the profile is re-fetched after a scored set', () async {
      final progression = _CountingProgression();
      final container = _container(
        extra: [progressionRepositoryProvider.overrideWithValue(progression)],
      );
      // Keep the profile alive like the Profile tab does.
      container.listen(profileProvider, (_, _) {});
      await container.read(profileProvider.future);
      expect(progression.meCalls, 1);

      final notifier = container.read(activeSessionProvider.notifier);
      await notifier.startHere();
      await notifier.submit(const <String, Object?>{});
      await container.read(profileProvider.future);

      expect(progression.meCalls, 2);
      expect(container.read(activeSessionProvider), isNull);
    });
  });

  group('error copy', () {
    test('contract codes become athlete-facing sentences', () {
      final message = describeError(
        const ApiException(
          code: ApiErrorCode.mockedLocationRejected,
          message: 'Mocked location rejected for production accounts. (J7)',
        ),
      );
      expect(message, isNot(contains('J7')));
      expect(message, contains('Mock locations'));
    });

    test('an unreachable server says so', () {
      expect(
        describeError(
          const ApiException(
            code: ApiErrorCode.internal,
            message: 'No response from session-start',
            statusCode: 0,
          ),
        ),
        contains("Can't reach RepRush"),
      );
    });

    test('location and gate messages pass through untouched', () {
      expect(describeError(const LocationException('Turn it on.')), 'Turn it on.');
      expect(describeError(const TrainingBlocked('Walk in.')), 'Walk in.');
    });

    test('only dead-session codes end the session; a network blip does not', () {
      expect(
        endsSession(
          const ApiException(
            code: ApiErrorCode.sessionExpired,
            message: '',
            statusCode: 409,
          ),
        ),
        isTrue,
      );
      expect(
        endsSession(
          const ApiException(
            code: ApiErrorCode.internal,
            message: '',
            statusCode: 0,
          ),
        ),
        isFalse,
      );
    });
  });
}
