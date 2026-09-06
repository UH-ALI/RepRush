/// Live-client tests: the repositories against a fake [ApiTransport], fed the
/// bytes the deployed routes actually emit.
///
/// THE PAYLOADS BELOW WERE CAPTURED OFF THE WIRE, not written out from the docs.
/// Each came from `npx supabase functions serve` running the real
/// `supabase/functions/` code against the migrated local Postgres:
///
///   - `_movementsJson` — `curl GET  /functions/v1/movements`, HTTP 200, 18 rows.
///   - `_startJson`     — `curl POST /functions/v1/session-start`, HTTP 200.
///   - `_submitJson`    — `deno task submit squat_20_clean`, HTTP 200, and that run
///                        reported "MATCHES THE GOLDEN".
///
/// Capturing matters because the two bugs worth catching here are wire-format bugs
/// the contract cannot show you: `/movements` answers with a BARE ARRAY where the
/// endpoint register implies an object, and FIVE of its eighteen `difficulty`
/// values arrive as `1` rather than `1.0`. A test written from the documentation
/// would assert neither, and both break the exercise picker on the first render.
///
/// NOT COVERED: `SupabaseTransport`. It needs a running stack and a plugin
/// binding, so it is exercised by `deno task submit` and by a device build rather
/// than here. Everything downstream of it — request shape, verb, response parsing,
/// error mapping — is what this file pins down.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/live/live_repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/models/models.dart';

// ---------------------------------------------------------------------------
// Captured payloads
// ---------------------------------------------------------------------------

/// `GET /movements`, complete and unedited. A BARE ARRAY — no envelope, no
/// `{"movements": [...]}` wrapper. Split one row per line purely so a catalogue
/// change shows up as a one-line diff; the bytes are the response's.
///
/// `squat` carries `repsTowardNextTier: 20` because this was captured for the dev
/// user after fixture submits had banked reps against it. It is per-user state, so
/// a fresh guest reads 0 here — the field is asserted as parsed, not as a constant
/// of the catalogue.
const _movementsJson =
    '['
    '{"id":"wall_sit","family":"hold","tier":1,"difficulty":0.8,'
    '"measurementType":"holdTime","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"plank","family":"hold","tier":2,"difficulty":1,'
    '"measurementType":"holdTime","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"side_plank","family":"hold","tier":3,"difficulty":1.3,'
    '"measurementType":"holdTime","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"l_sit","family":"hold","tier":4,"difficulty":2.2,'
    '"measurementType":"holdTime","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"jumping_jack","family":"jump","tier":2,"difficulty":0.8,'
    '"measurementType":"repBodyweight","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"burpee","family":"jump","tier":3,"difficulty":2.2,'
    '"measurementType":"repBodyweight","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"dead_hang","family":"pull","tier":1,"difficulty":0.8,'
    '"measurementType":"holdTime","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"pull_up","family":"pull","tier":2,"difficulty":1.8,'
    '"measurementType":"repBodyweight","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"wide_grip_pull_up","family":"pull","tier":3,"difficulty":2.2,'
    '"measurementType":"repBodyweight","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"muscle_up","family":"pull","tier":4,"difficulty":3,'
    '"measurementType":"repBodyweight","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"knee_push_up","family":"push","tier":1,"difficulty":0.7,'
    '"measurementType":"repBodyweight","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"push_up","family":"push","tier":2,"difficulty":1,'
    '"measurementType":"repBodyweight","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"diamond_push_up","family":"push","tier":3,"difficulty":1.4,'
    '"measurementType":"repBodyweight","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"archer_push_up","family":"push","tier":4,"difficulty":2,'
    '"measurementType":"repBodyweight","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"assisted_squat","family":"squat","tier":1,"difficulty":0.7,'
    '"measurementType":"repBodyweight","unlocked":true,"repsTowardNextTier":0},'
    '{"id":"squat","family":"squat","tier":2,"difficulty":1,'
    '"measurementType":"repBodyweight","unlocked":true,"repsTowardNextTier":20},'
    '{"id":"jump_squat","family":"squat","tier":3,"difficulty":1.5,'
    '"measurementType":"repBodyweight","unlocked":false,"repsTowardNextTier":0},'
    '{"id":"pistol_squat","family":"squat","tier":4,"difficulty":2.4,'
    '"measurementType":"repBodyweight","unlocked":false,"repsTowardNextTier":0}'
    ']';

/// `POST /session/start` for the demo venue (51.5074, -0.1278) at
/// `spot_riverside_rig`. `sessionId` and both timestamps are unique to the call;
/// they are kept as captured rather than normalised, because the 4-hour gap
/// between them is the invariant under test.
const _startJson =
    '{"sessionId":"49ef2534-0933-4c1a-9939-c8b4c4e8a889",'
    '"serverStartMs":1788706879194,"movementConfigVersion":"2026-08-30.1",'
    '"hexH3":"88195da49bfffff","spotId":"spot_riverside_rig",'
    '"expiresAtMs":1788721279194}';

/// `POST /session/submit` for fixture `squat_20_clean`, first submit of the day.
/// `power` carries the full float tail the route emits — `19.639920000000004`, not
/// the `19.63992` a golden fixture rounds to — and asserting the unrounded value is
/// the point: the client must not be the place precision is lost.
const _submitJson =
    '{"xp":20,"level":1,"levelUps":[],'
    '"hexResult":{"h3":"88195da49bfffff","captured":true,'
    '"power":19.639920000000004,"yourPower":19.639920000000004},'
    '"spotResult":null,"rankChange":null,"unlocks":[],"prs":[],'
    '"achievements":[],"voided":false}';

/// A stand-in for Evidence — deliberately NOT a real fixture.
///
/// The repository takes Evidence as an opaque `Map<String, Object?>` (§state rule
/// 4: Track A's `EvidenceBuilder` owns that shape), so a test that depended on its
/// internals would be asserting a contract this layer is forbidden to know, and
/// would break every time A revised it. What is asserted instead is the stronger
/// and simpler property: the map that goes in is the map that goes out.
final _evidence = <String, Object?>{
  'sessionId': '49ef2534-0933-4c1a-9939-c8b4c4e8a889',
  'movementConfigVersion': '2026-08-30.1',
  'movementId': 'squat',
  'set': <String, Object?>{'reps': 20, 'romScore': 0.82},
  'reps': <Object?>[
    <String, Object?>{'peakAngleDeg': 71.4},
  ],
  'trace': <Object?>[],
};

// ---------------------------------------------------------------------------
// The fake transport
// ---------------------------------------------------------------------------

/// One recorded call. [verb] is here because "which HTTP method did the repository
/// ask for" is a real failure mode: `FunctionsClient.invoke` defaults to POST and
/// does not infer GET from a null body.
class _Call {
  const _Call(this.verb, this.function, this.body);

  final String verb;
  final String function;
  final Map<String, Object?>? body;

  @override
  String toString() => '$verb $function';
}

/// Stands in for Supabase. Records every call, then answers from [respond] or
/// throws from [failWith] — never both, and never anything the real transport
/// could not throw.
class _FakeTransport implements ApiTransport {
  _FakeTransport({this.respond, this.failWith});

  final Object? Function(String function)? respond;
  final ApiException? Function(String function)? failWith;

  final List<_Call> calls = <_Call>[];

  _Call get only {
    expect(calls, hasLength(1), reason: 'expected exactly one call');
    return calls.single;
  }

  @override
  Future<Object?> get(String function) => _record('GET', function, null);

  @override
  Future<Object?> post(String function, Map<String, Object?> body) =>
      _record('POST', function, body);

  Future<Object?> _record(
    String verb,
    String function,
    Map<String, Object?>? body,
  ) async {
    calls.add(_Call(verb, function, body));
    final failure = failWith?.call(function);
    if (failure != null) throw failure;
    return respond?.call(function);
  }
}

void main() {
  group('LiveSessionRepository.start', () {
    test(
      'posts the contract request body to the deployed function name',
      () async {
        final transport = _FakeTransport(
          respond: (_) => jsonDecode(_startJson),
        );
        final repo = LiveSessionRepository(transport: transport);

        await repo.start(
          location: const SessionLocation(
            lat: 51.5074,
            lng: -0.1278,
            accuracyM: 8,
          ),
          spotId: 'spot_riverside_rig',
        );

        final call = transport.only;
        // The deployed DIRECTORY name, which is what Kong routes on — not the
        // contract's slashed `POST /session/start`.
        expect(call.verb, 'POST');
        expect(call.function, 'session-start');
        expect(call.body, <String, Object?>{
          'location': <String, Object?>{
            'lat': 51.5074,
            'lng': -0.1278,
            'accuracyM': 8.0,
            'isMocked': false,
          },
          'spotId': 'spot_riverside_rig',
        });
      },
    );

    test('sends spotId as an explicit null rather than dropping the key', () async {
      final transport = _FakeTransport(respond: (_) => jsonDecode(_startJson));

      await LiveSessionRepository(transport: transport).start(
        location: const SessionLocation(
          lat: 51.5074,
          lng: -0.1278,
          accuracyM: 8,
        ),
      );

      // The register's shape is `{"location": {...}, "spotId": null}`. Omitting the
      // key is usually equivalent in a JS handler, but "usually" is not something
      // to ship to a demo: a route that distinguishes absent from null would read
      // a dropped key as a malformed request.
      final body = transport.only.body!;
      expect(body.containsKey('spotId'), isTrue);
      expect(body['spotId'], isNull);
    });

    test('reads the captured response field by field', () async {
      final transport = _FakeTransport(respond: (_) => jsonDecode(_startJson));

      final start = await LiveSessionRepository(transport: transport).start(
        location: const SessionLocation(
          lat: 51.5074,
          lng: -0.1278,
          accuracyM: 8,
        ),
        spotId: 'spot_riverside_rig',
      );

      expect(start.sessionId, '49ef2534-0933-4c1a-9939-c8b4c4e8a889');
      expect(start.serverStartMs, 1788706879194);
      expect(start.movementConfigVersion, '2026-08-30.1');
      // The server-computed hex for the demo venue, at resolution 8. The client
      // never derives this itself, which is why the call exists.
      expect(start.hexH3, '88195da49bfffff');
      expect(start.spotId, 'spot_riverside_rig');
      expect(start.expiresAtMs, 1788721279194);
    });

    test('the captured session lives exactly the 4 hours I2 promises', () async {
      final transport = _FakeTransport(respond: (_) => jsonDecode(_startJson));

      final start = await LiveSessionRepository(transport: transport).start(
        location: const SessionLocation(
          lat: 51.5074,
          lng: -0.1278,
          accuracyM: 8,
        ),
      );

      // Both values come from the same server clock, so the difference is exact
      // and needs no tolerance. A drift here means the expiry stopped being
      // server-decided.
      expect(start.expiresAtMs - start.serverStartMs, 4 * 60 * 60 * 1000);
    });
  });

  group('LiveSessionRepository.submit', () {
    test('forwards evidence untouched and adds no score of its own', () async {
      // I1: the client never sends a score. The assertion is identity on the whole
      // map, which is strictly stronger than checking for forbidden keys — a field
      // added here for any reason, scoring or not, fails it.
      final transport = _FakeTransport(respond: (_) => jsonDecode(_submitJson));

      await LiveSessionRepository(transport: transport).submit(_evidence);

      final call = transport.only;
      expect(call.verb, 'POST');
      expect(call.function, 'session-submit');
      expect(call.body, same(_evidence));
      expect(call.body!.keys, unorderedEquals(_evidence.keys));
      for (final forbidden in [
        'score',
        'xp',
        'formFactor',
        'points',
        'power',
      ]) {
        expect(
          call.body!.containsKey(forbidden),
          isFalse,
          reason:
              'the client must never send "$forbidden"; the server recomputes it',
        );
      }
    });

    test(
      'reads the captured C4 response, keeping full float precision',
      () async {
        final transport = _FakeTransport(
          respond: (_) => jsonDecode(_submitJson),
        );

        final result = await LiveSessionRepository(
          transport: transport,
        ).submit(_evidence);

        expect(result.xp, 20);
        expect(result.level, 1);
        expect(result.levelUps, isEmpty);
        expect(result.voided, isFalse);
        expect(result.spotResult, isNull);
        expect(result.rankChange, isNull);
        expect(result.hexResult!.h3, '88195da49bfffff');
        expect(result.hexResult!.captured, isTrue);
        expect(result.hexResult!.power, 19.639920000000004);
        expect(result.hexResult!.yourPower, 19.639920000000004);
      },
    );

    test('a contract error reaches the caller unchanged', () async {
      // Repositories do not catch. The transport already maps to ApiException, so
      // a second translation here would either lose the code the UI switches on or
      // invent a message the server did not send.
      final transport = _FakeTransport(
        failWith: (_) => ApiException.fromResponse(
          statusCode: 409,
          body: <String, Object?>{
            'code': ApiErrorCode.sessionAlreadyUsed,
            'message': 'session 49ef2534 was already submitted',
          },
        ),
      );

      await expectLater(
        LiveSessionRepository(transport: transport).submit(_evidence),
        throwsA(
          isA<ApiException>()
              .having((e) => e.code, 'code', ApiErrorCode.sessionAlreadyUsed)
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.unknownCode, 'unknownCode', isFalse),
        ),
      );
    });
  });

  group('LiveProgressionRepository.movements', () {
    test('GETs the deployed function — it must not POST', () async {
      final transport = _FakeTransport(
        respond: (_) => jsonDecode(_movementsJson),
      );

      await LiveProgressionRepository(
        transport: transport,
        fallback: StubProgressionRepository(),
      ).movements();

      expect(transport.only.verb, 'GET');
      expect(transport.only.function, 'movements');
      expect(transport.only.body, isNull);
    });

    test('reads the bare array, all eighteen rows', () async {
      final transport = _FakeTransport(
        respond: (_) => jsonDecode(_movementsJson),
      );

      final movements = await LiveProgressionRepository(
        transport: transport,
        fallback: StubProgressionRepository(),
      ).movements();

      expect(movements, hasLength(18));
      expect(
        movements.map((m) => m.id),
        containsAll(<String>[
          'squat',
          'push_up',
          'pull_up',
          'plank',
          'muscle_up',
        ]),
      );
      // Rows arrive family-then-tier, which is the order the picker renders.
      expect(movements.first.id, 'wall_sit');
      expect(movements.last.id, 'pistol_squat');
    });

    test('survives the five integral difficulty values', () async {
      final raw = jsonDecode(_movementsJson) as List<Object?>;

      // First establish the trap is real rather than theoretical: the server
      // genuinely sent these as ints, so a bare `as double` would throw.
      final integrals = raw
          .cast<Map<String, Object?>>()
          .where((row) => row['difficulty'] is int)
          .toList();
      expect(
        integrals.map((row) => row['id']),
        unorderedEquals(<String>[
          'plank',
          'push_up',
          'squat',
          'archer_push_up',
          'muscle_up',
        ]),
        reason: 'the catalogue changed; recheck the captured payload above',
      );

      final transport = _FakeTransport(respond: (_) => raw);
      final movements = await LiveProgressionRepository(
        transport: transport,
        fallback: StubProgressionRepository(),
      ).movements();

      double difficultyOf(String id) =>
          movements.firstWhere((m) => m.id == id).difficulty;
      expect(difficultyOf('plank'), 1.0);
      expect(difficultyOf('archer_push_up'), 2.0);
      expect(difficultyOf('muscle_up'), 3.0);
      expect(difficultyOf('wall_sit'), 0.8);
      expect(difficultyOf('pistol_squat'), 2.4);
    });

    test(
      'maps enums from their wire names, and per-user state as an int',
      () async {
        final transport = _FakeTransport(
          respond: (_) => jsonDecode(_movementsJson),
        );

        final movements = await LiveProgressionRepository(
          transport: transport,
          fallback: StubProgressionRepository(),
        ).movements();
        final squat = movements.firstWhere((m) => m.id == 'squat');

        expect(squat.family, MovementFamily.squat);
        expect(squat.measurementType, MeasurementType.repBodyweight);
        expect(squat.tier, 2);
        expect(squat.unlocked, isTrue);
        // Banked reps for the user this was captured as — not a catalogue constant.
        expect(squat.repsTowardNextTier, 20);

        final wallSit = movements.firstWhere((m) => m.id == 'wall_sit');
        expect(wallSit.family, MovementFamily.hold);
        expect(wallSit.measurementType, MeasurementType.holdTime);
        expect(wallSit.unlocked, isTrue);
      },
    );

    test('an unrecognised family throws naming the field and the options', () {
      // A catalogue row the client has not been rebuilt for is a real scenario —
      // movements are frozen Day 1 but the SEED is not, and the message is the
      // difference between a five-minute fix and an afternoon.
      expect(
        () => Movement.fromJson(<String, Object?>{
          'id': 'handstand_push_up',
          'family': 'invert',
          'tier': 4,
          'difficulty': 2.6,
          'measurementType': 'repBodyweight',
          'unlocked': false,
          'repsTowardNextTier': 0,
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('movement.family'),
              contains('invert'),
              contains('squat | push | pull | hold | jump'),
            ),
          ),
        ),
      );
    });
  });

  group('LiveProgressionRepository.me', () {
    test('delegates to the fallback and never reaches the network', () async {
      // `GET /me` has no deployed route. Splitting per method keeps the Profile
      // screen on realistic stub data instead of a 404.
      final transport = _FakeTransport(
        respond: (_) => fail('me() must not call the transport'),
      );
      final stub = StubProgressionRepository();

      final profile = await LiveProgressionRepository(
        transport: transport,
        fallback: stub,
      ).me();

      expect(transport.calls, isEmpty);
      expect(profile.handle, 'demo_athlete');
      // The stub returns a `const UserProfile`, so identity proves this is a real
      // pass-through and not a copy that happens to look correct.
      expect(profile, same(await stub.me()));
    });
  });

  group('backend selection', () {
    test('a build with no dart-defines is stub mode and needs no key', () {
      // This is the case C and the demo phone are in by default: `flutter run`
      // with no flags must not require a Supabase key, must not throw, and must
      // not reach a URL.
      final config = BackendConfig.fromEnvironment();

      expect(config.mode, ApiMode.stub);
      expect(config.isLive, isFalse);
      expect(config.supabaseUrl, BackendConfig.defaultSupabaseUrl);
      expect(config.anonKey, isEmpty);
      expect(config.devEmail, isNull);
      expect(config.devPassword, isNull);
    });

    test(
      'ApiMode.parse accepts the two modes, tolerating case and padding',
      () {
        expect(ApiMode.parse('live'), ApiMode.live);
        expect(ApiMode.parse('stub'), ApiMode.stub);
        expect(ApiMode.parse('LIVE'), ApiMode.live);
        expect(ApiMode.parse('  Stub '), ApiMode.stub);
      },
    );

    test('ApiMode.parse refuses anything else, naming both valid values', () {
      // Defaulting to stub instead would fail as "the app is still using stubs" —
      // true, and no help at all in finding the typo that caused it.
      expect(
        () => ApiMode.parse('prod'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('prod'), contains('stub'), contains('live')),
          ),
        ),
      );
    });

    test('live mode refuses to build without a key', () {
      // Otherwise the first symptom is a 401 on every request, which reads as an
      // auth bug or a dead backend rather than a missing build flag.
      expect(
        () => BackendConfig.parse(api: 'live'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('REPRUSH_SUPABASE_ANON_KEY'),
              contains('npx supabase status'),
            ),
          ),
        ),
      );
    });

    test('live mode refuses a URL with no scheme', () {
      expect(
        () => BackendConfig.parse(
          api: 'live',
          url: '127.0.0.1:54321',
          anonKey: 'k',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('127.0.0.1:54321'), contains('http://')),
          ),
        ),
      );
    });

    test('a trailing slash on the URL is stripped', () {
      // The flag is normally pasted from a browser bar, and `http://host/` +
      // `/functions/v1` is a double slash whose routing depends on the proxy.
      expect(
        BackendConfig.parse(
          api: 'live',
          url: 'http://192.168.1.20:54321///',
          anonKey: 'k',
        ).supabaseUrl,
        'http://192.168.1.20:54321',
      );
    });

    test('stub mode validates nothing, so a bad URL cannot block it', () {
      // The stub build must never be able to fail on configuration it does not use.
      final config = BackendConfig.parse(api: 'stub', url: 'nonsense');
      expect(config.isLive, isFalse);
      expect(config.supabaseUrl, 'nonsense');
    });

    test('half a dev credential pair is dropped, not half-applied', () {
      final noPassword = BackendConfig.parse(
        api: 'stub',
        devEmail: 'dev@x.local',
      );
      expect(noPassword.devEmail, 'dev@x.local');
      // The email survives but the pair is unusable, so the password path must not
      // run on it and then report a bare "sign-in failed".
      expect(noPassword.devPassword, isNull);

      final noEmail = BackendConfig.parse(api: 'stub', devPassword: 'hunter2');
      expect(noEmail.devEmail, isNull);
      expect(noEmail.devPassword, isNull);

      final both = BackendConfig.parse(
        api: 'stub',
        devEmail: 'dev@x.local',
        devPassword: 'hunter2',
      );
      expect(both.devEmail, 'dev@x.local');
      expect(both.devPassword, 'hunter2');
    });
  });
}
