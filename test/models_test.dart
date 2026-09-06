/// Round-trip tests for the session models' hand-written serialization
/// (backend-scaffolding.md §8: `fromJson(x).toJson() == x`).
///
/// THE JSON LITERALS BELOW ARE CAPTURED, NOT INVENTED. Each was printed by the
/// real backend — `node tool/c4_payloads.ts` runs every authored fixture through
/// the scoring pipeline and emits exactly what `POST /session/submit` returns, and
/// `stubStart(1757000000000)` emits exactly what `POST /session/start` returns.
/// Anchoring to those bytes is what keeps this file honest: feeding `toJson`
/// output back into `fromJson` would pass no matter which field names the server
/// actually used, which is the one thing worth testing here.
///
/// Two shapes could NOT be captured and are written from the TypeScript
/// interfaces instead, marked at each site: a populated `prs` entry and a
/// non-null `rankChange`. `buildConsequences` returns `prs: []` and
/// `rankChange: null` unconditionally — the territory half of C4 is a documented
/// stub — so no server payload exercising them exists yet.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/models/models.dart';

// ---------------------------------------------------------------------------
// Captured payloads
// ---------------------------------------------------------------------------

/// `POST /session/start`, from `stubStart(1757000000000)`.
const _startJson =
    '{"sessionId":"00000000-0000-4000-8000-000000000001",'
    '"serverStartMs":1757000000000,"movementConfigVersion":"2026-08-30.1",'
    '"hexH3":"8a2a1072b59ffff","spotId":"spot_riverside_rig",'
    '"expiresAtMs":1757014400000}';

/// `POST /session/submit` for fixture `squat_20_clean`, prior lifetime XP 0.
const _submitCleanJson =
    '{"xp":20,"level":1,"levelUps":[],'
    '"hexResult":{"h3":"8a2a1072b59ffff","captured":true,"power":19.63992,'
    '"yourPower":19.63992},"spotResult":null,"rankChange":null,'
    '"unlocks":[],"prs":[],"achievements":[],"voided":false}';

/// The same fixture with prior lifetime XP 240, so a level is crossed.
const _submitLevelUpJson =
    '{"xp":20,"level":2,"levelUps":[2],'
    '"hexResult":{"h3":"8a2a1072b59ffff","captured":true,"power":19.63992,'
    '"yourPower":19.63992},"spotResult":null,"rankChange":null,'
    '"unlocks":[],"prs":[],"achievements":[],"voided":false}';

/// A session that awarded nothing — the tier-gated and fully-capped branch, where
/// `hexResult` must be null rather than present with `power: 0`.
const _submitNothingJson =
    '{"xp":0,"level":1,"levelUps":[],"hexResult":null,"spotResult":null,'
    '"rankChange":null,"unlocks":[],"prs":[],"achievements":[],"voided":false}';

/// THE INT-VALUED DOUBLE. `awardedTotal` lands on exactly 6 — 20 reps × 0.60
/// formFactor floor × 0.50 tempo floor — and `JSON.stringify` emits a JS number
/// with no fractional part as `6`, not `6.0`. Captured, and the reason every
/// numeric field in models.dart goes through `_asDouble` instead of a cast.
const _submitIntegralJson =
    '{"xp":6,"level":1,"levelUps":[],'
    '"hexResult":{"h3":"8a2a1072b59ffff","captured":true,"power":6,'
    '"yourPower":6},"spotResult":null,"rankChange":null,'
    '"unlocks":[],"prs":[],"achievements":[],"voided":false}';

/// A capture at a named spot, so `spotResult` is populated.
const _submitSpotJson =
    '{"xp":20,"level":1,"levelUps":[],'
    '"hexResult":{"h3":"8a2a1072b59ffff","captured":true,"power":19.63992,'
    '"yourPower":19.63992},'
    '"spotResult":{"spotId":"spot_riverside_rig","captured":true,"rank":1},'
    '"rankChange":null,"unlocks":[],"prs":[],"achievements":[],"voided":false}';

/// The Class-1 gate rejection envelope, fixture `squat_replay_bad_clock`. The
/// message is the real one, not a paraphrase: `validation/session.ts` builds
/// "Claimed timeline does not fit the server-observed window: ${clock.reason}
/// (I3)." with `clock.reason` from `validation/wallclock.ts`. Only `code` is
/// contract-stable, so the test below asserts on the numbers in the message
/// rather than on the prose — rewording the sentence must not break a client.
const _gateJson =
    '{"code":"TIMELINE_OUT_OF_WINDOW","message":"Claimed timeline does not fit '
    'the server-observed window: claimed 177100 ms of work inside a 40000 ms '
    'observed window (I3)."}';

/// NOT CAPTURED — `buildConsequences` returns `prs: []`, `unlocks: []` and
/// `achievements: []` unconditionally, because the stub's rule is never to
/// fabricate a claim it cannot verify. The SHAPES come from `PersonalRecordOut`
/// in `_shared/stubs/consequences.ts`; the `metric` and `achievements`
/// VOCABULARY comes from `StubSessionRepository.submit`, which is the only code
/// in the repo that actually produces either. Neither vocabulary is pinned by
/// api-contract.md — worth naming one in standup before the real PR and
/// achievement tables land.
/// `value` is 20, an int on the wire, which is the same trap as `power` above on
/// a max-reps record.
const _submitWithPrJson =
    '{"xp":20,"level":1,"levelUps":[],"hexResult":null,"spotResult":null,'
    '"rankChange":null,"unlocks":["pistol_squat"],'
    '"prs":[{"movementId":"squat","metric":"max_reps","value":20}],'
    '"achievements":["first_capture"],"voided":false}';

/// NOT CAPTURED — `rankChange` is always null because it needs
/// `territory_leaderboard`. Written from `RankChangeOut`.
const _submitWithRankJson =
    '{"xp":20,"level":1,"levelUps":[],"hexResult":null,"spotResult":null,'
    '"rankChange":{"before":4,"after":2},"unlocks":[],"prs":[],'
    '"achievements":[],"voided":false}';

const _allSubmitJson = [
  _submitCleanJson,
  _submitLevelUpJson,
  _submitNothingJson,
  _submitIntegralJson,
  _submitSpotJson,
  _submitWithPrJson,
  _submitWithRankJson,
];

void main() {
  group('SubmitResult', () {
    test('reads the captured squat_20_clean C4 field by field', () {
      final result = SubmitResult.fromJson(jsonDecode(_submitCleanJson));

      expect(result.xp, 20);
      expect(result.level, 1);
      expect(result.levelUps, isEmpty);
      expect(result.voided, isFalse);
      expect(result.unlocks, isEmpty);
      expect(result.prs, isEmpty);
      expect(result.achievements, isEmpty);
      expect(result.spotResult, isNull);
      expect(result.rankChange, isNull);

      final hex = result.hexResult;
      expect(hex, isNotNull);
      expect(hex!.h3, '8a2a1072b59ffff');
      expect(hex.captured, isTrue);
      expect(hex.power, 19.63992);
      expect(hex.yourPower, 19.63992);
    });

    test('round-trips every captured payload: fromJson(x).toJson() == x', () {
      // The §8 convention. Comparing against the ORIGINAL decoded map rather
      // than against a second decode of toJson output is what makes this a
      // wire-format test and not a self-consistency test.
      for (final json in _allSubmitJson) {
        final original = jsonDecode(json) as Map<String, Object?>;
        expect(
          SubmitResult.fromJson(original).toJson(),
          original,
          reason: 'round trip diverged for $json',
        );
      }
    });

    test('an int-valued double on the wire does not throw', () {
      // First establish the trap is real: the server genuinely sent an int here.
      final raw = jsonDecode(_submitIntegralJson) as Map<String, Object?>;
      final hex = raw['hexResult']! as Map<String, Object?>;
      expect(
        hex['power'],
        isA<int>(),
        reason: 'expected the captured int form',
      );
      expect(hex['power'], isNot(isA<double>()));

      // Then that the model survives it, and keeps the value exact.
      final result = SubmitResult.fromJson(raw);
      expect(result.hexResult!.power, 6.0);
      expect(result.hexResult!.yourPower, 6.0);
      expect(result.xp, 6);
    });

    test('a crossed level arrives in levelUps', () {
      final result = SubmitResult.fromJson(jsonDecode(_submitLevelUpJson));
      expect(result.level, 2);
      expect(result.levelUps, [2]);
    });

    test('a session that awarded nothing reports no capture', () {
      final result = SubmitResult.fromJson(jsonDecode(_submitNothingJson));
      expect(result.xp, 0);
      expect(result.hexResult, isNull);
      expect(result.spotResult, isNull);
    });

    test('a spot capture populates spotResult', () {
      final spot = SubmitResult.fromJson(
        jsonDecode(_submitSpotJson),
      ).spotResult;
      expect(spot, isNotNull);
      expect(spot!.spotId, 'spot_riverside_rig');
      expect(spot.captured, isTrue);
      expect(spot.rank, 1);
    });

    test('personal records and unlocks parse, with an int-valued metric', () {
      final result = SubmitResult.fromJson(jsonDecode(_submitWithPrJson));
      expect(result.unlocks, ['pistol_squat']);
      expect(result.achievements, ['first_capture']);
      expect(result.prs, hasLength(1));

      final pr = result.prs.single;
      expect(pr.movementId, 'squat');
      expect(pr.metric, 'max_reps');
      // 20 on the wire is an int; `value` is a double. Same trap as `power`.
      expect(pr.value, 20.0);
    });

    test('rankChange parses when the leaderboard half lands', () {
      final rank = SubmitResult.fromJson(
        jsonDecode(_submitWithRankJson),
      ).rankChange;
      expect(rank, isNotNull);
      expect(rank!.before, 4);
      expect(rank.after, 2);
    });

    test('an absent voided defaults to false', () {
      // Tolerance, not licence: the live route always sends the key. But a
      // client that required it would fail on a stored session read back later,
      // which is exactly when `voided: true` starts appearing.
      final map = jsonDecode(_submitCleanJson) as Map<String, Object?>
        ..remove('voided');
      expect(SubmitResult.fromJson(map).voided, isFalse);
    });
  });

  group('SessionStart', () {
    test('reads the captured start response', () {
      final start = SessionStart.fromJson(jsonDecode(_startJson));

      expect(start.sessionId, '00000000-0000-4000-8000-000000000001');
      expect(start.serverStartMs, 1757000000000);
      expect(start.movementConfigVersion, '2026-08-30.1');
      expect(start.hexH3, '8a2a1072b59ffff');
      expect(start.spotId, 'spot_riverside_rig');
      expect(start.expiresAtMs, 1757014400000);
    });

    test('the 4 h one-shot window (I2) is what the server issued', () {
      final start = SessionStart.fromJson(jsonDecode(_startJson));
      expect(start.expiresAtMs - start.serverStartMs, 4 * 60 * 60 * 1000);
    });

    test('round-trips', () {
      final original = jsonDecode(_startJson) as Map<String, Object?>;
      expect(SessionStart.fromJson(original).toJson(), original);
    });

    test('the client and server venue literals still agree', () {
      // venue.ts says the two copies "MUST match" and are duplicated rather than
      // generated because there is no shared build step. Nothing else in the repo
      // checks that claim, and a drift surfaces as a rendering bug on the Day-3
      // swap rather than as a diff anyone thought to look for.
      final start = SessionStart.fromJson(jsonDecode(_startJson));
      expect(start.sessionId, DemoVenue.sessionId);
      expect(start.hexH3, DemoVenue.demoHexH3);
      expect(start.spotId, DemoVenue.demoSpotId);
      expect(start.movementConfigVersion, DemoVenue.movementConfigVersion);
    });
  });

  group('SessionLocation', () {
    const location = SessionLocation(
      lat: 51.5074,
      lng: -0.1278,
      accuracyM: 8,
      isMocked: false,
    );

    test('serialises to the request block the contract names', () {
      // §endpoints: `{ "location": { lat, lng, accuracyM, isMocked }, "spotId" }`.
      expect(location.toJson(), <String, Object?>{
        'lat': 51.5074,
        'lng': -0.1278,
        'accuracyM': 8,
        'isMocked': false,
      });
    });

    test('round-trips', () {
      final json = location.toJson();
      final back = SessionLocation.fromJson(json);
      expect(back.toJson(), json);
      expect(back.lat, location.lat);
      expect(back.isMocked, location.isMocked);
    });

    test('an absent isMocked defaults to false', () {
      // Matches `parseStartRequest`, which reads `l["isMocked"] === true`. A
      // client stricter than the server would reject its own request echoed back.
      final parsed = SessionLocation.fromJson(<String, Object?>{
        'lat': 51.5074,
        'lng': -0.1278,
        'accuracyM': 8,
      });
      expect(parsed.isMocked, isFalse);
    });

    test('accuracyM survives an int on the wire', () {
      // Geolocator reports whole metres often enough that this is the common
      // case, not the edge case.
      final parsed = SessionLocation.fromJson(<String, Object?>{
        'lat': 51.5074,
        'lng': -0.1278,
        'accuracyM': 8,
        'isMocked': false,
      });
      expect(parsed.accuracyM, 8.0);
    });
  });

  group('ApiException.fromResponse', () {
    test('reads the contract error envelope', () {
      final error = ApiException.fromResponse(
        statusCode: 400,
        body: jsonDecode(_gateJson),
      );
      expect(error.code, ApiErrorCode.timelineOutOfWindow);
      expect(error.statusCode, 400);
      expect(error.unknownCode, isFalse);
      expect(error.message, contains('177100 ms'));
      expect(error.message, contains('observed window'));
    });

    test('flags a code this client has never seen', () {
      // §Common rules: "Unknown codes are a contract bug — report them, don't
      // guess at handling." Flagging is how "report them" is implemented; a
      // fallback mapping would swallow exactly the thing worth surfacing.
      final error = ApiException.fromResponse(
        statusCode: 409,
        body: <String, Object?>{'code': 'SOMETHING_NEW', 'message': 'x'},
      );
      expect(error.unknownCode, isTrue);
      expect(error.code, 'SOMETHING_NEW');
      expect(error.toString(), contains('UNKNOWN CODE'));
    });

    test('tolerates a body that is not an envelope at all', () {
      // A Supabase 502 page arrives as HTML. Throwing while handling an error
      // response would replace a diagnosable failure with an undiagnosable one.
      final error = ApiException.fromResponse(
        statusCode: 502,
        body: '<html>Bad Gateway</html>',
      );
      expect(error.statusCode, 502);
      expect(error.code, ApiErrorCode.internal);
      expect(error.message, contains('502'));
    });

    test('tolerates a null body', () {
      final error = ApiException.fromResponse(statusCode: 500, body: null);
      expect(error.code, ApiErrorCode.internal);
      expect(error.statusCode, 500);
    });

    test('the six codes the backend added are all known here', () {
      // responses.ts keeps its own table and says the two "MUST stay in sync".
      // This is the check that makes that sentence enforceable.
      for (final code in [
        ApiErrorCode.unknownSession,
        ApiErrorCode.evidenceMalformed,
        ApiErrorCode.malformedRequest,
        ApiErrorCode.rateLimited,
        ApiErrorCode.scoringFailed,
        ApiErrorCode.internal,
      ]) {
        expect(ApiErrorCode.isKnown(code), isTrue, reason: '$code missing');
      }
    });

    test('every code the stubs throw is known', () {
      // Guards the other direction: `all` must not have been built by copying
      // only the new half.
      for (final code in [
        ApiErrorCode.unauthenticated,
        ApiErrorCode.gpsTooInaccurate,
        ApiErrorCode.implausibleTravel,
        ApiErrorCode.mockedLocationRejected,
        ApiErrorCode.sessionAlreadyUsed,
        ApiErrorCode.sessionExpired,
        ApiErrorCode.timelineOutOfWindow,
        ApiErrorCode.configVersionMismatch,
        ApiErrorCode.sessionContextMismatch,
        ApiErrorCode.bboxTooLarge,
        ApiErrorCode.unknownHex,
        ApiErrorCode.radiusTooLarge,
        ApiErrorCode.unknownSpotType,
        ApiErrorCode.spotTooClose,
        ApiErrorCode.outOfProximity,
        ApiErrorCode.unknownTab,
        ApiErrorCode.notComplete,
        ApiErrorCode.alreadyClaimed,
        ApiErrorCode.attestationInvalid,
      ]) {
        expect(ApiErrorCode.isKnown(code), isTrue, reason: '$code missing');
      }
    });
  });

  group('malformed payloads', () {
    test('a missing field names itself', () {
      final map = jsonDecode(_submitCleanJson) as Map<String, Object?>
        ..remove('xp');
      expect(
        () => SubmitResult.fromJson(map),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('xp'),
          ),
        ),
      );
    });

    test('a wrong type names the field and the type it got', () {
      // The alternative is "type 'String' is not a subtype of type 'double' in
      // type cast", which does not say which of the four numeric fields failed.
      final map = jsonDecode(_submitCleanJson) as Map<String, Object?>
        ..['hexResult'] = <String, Object?>{
          'h3': '8a2a1072b59ffff',
          'captured': true,
          'power': 'lots',
          'yourPower': 1,
        };
      expect(
        () => SubmitResult.fromJson(map),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('hexResult.power'), contains('String')),
          ),
        ),
      );
    });

    test('a fractional xp is an error, not a silent truncation', () {
      // The server rounds; if it ever stops, rounding again here would hide it.
      final map = jsonDecode(_submitCleanJson) as Map<String, Object?>
        ..['xp'] = 20.5;
      expect(() => SubmitResult.fromJson(map), throwsFormatException);
    });

    test('a payload that is not an object is rejected', () {
      expect(() => SubmitResult.fromJson(<Object?>[]), throwsFormatException);
      expect(() => SessionStart.fromJson('nope'), throwsFormatException);
    });
  });
}
