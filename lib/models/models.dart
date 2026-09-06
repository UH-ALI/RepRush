/// Typed models generated from [docs/api-contract.md](../../docs/api-contract.md) —
/// the interface all three tracks meet at (roles.md §4 Seam 1, §5).
///
/// Ownership: B. Field names mirror the endpoint register (§endpoints) and the
/// Evidence shape (§evidence) verbatim. Do not add fields that the contract
/// does not name — additive contract changes are announced in standup.
///
/// Serialization is hand-written `fromJson`/`toJson` per
/// [backend-scaffolding.md §8](../../docs/backend-scaffolding.md) — codegen is
/// explicitly ruled out for a seven-day build. Only the session types carry it so
/// far, because they are the only ones with a server behind them
/// (`supabase/functions/session-start`, `session-submit`); the `_as*` helpers
/// below are what the remaining types should reuse rather than reinvent.
/// Round-trip convention, also §8: `fromJson(x).toJson() == x`.
library;

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Errors — stable machine-readable codes (§endpoints · Common rules)
// ---------------------------------------------------------------------------

/// A contract error. `code` is one of the stable machine-readable codes named
/// in §endpoints; unknown codes are a contract bug.
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode = 400,
    this.unknownCode = false,
  });

  final String code;
  final String message;
  final int statusCode;

  /// True when the server sent a code this client has never heard of. Set only by
  /// [ApiException.fromResponse]; the stubs throw known codes by construction.
  final bool unknownCode;

  /// Parses the contract's error envelope — `{ code, message }` on every 4xx
  /// (§endpoints · Common rules).
  ///
  /// Tolerates a body that is not that envelope. A Supabase 502 page or a proxy
  /// error arrives as a bare string, and throwing *while handling an error
  /// response* replaces a diagnosable failure with an undiagnosable one — the
  /// status code is still a fact, so it goes in the message instead.
  factory ApiException.fromResponse({required int statusCode, Object? body}) {
    if (body is! Map) {
      return ApiException(
        code: ApiErrorCode.internal,
        message: 'HTTP $statusCode with no JSON error envelope.',
        statusCode: statusCode,
      );
    }
    final envelope = _asMap(body, 'error envelope');
    final code =
        _asStringOrNull(envelope['code'], 'code') ?? ApiErrorCode.internal;
    return ApiException(
      code: code,
      message:
          _asStringOrNull(envelope['message'], 'message') ??
          'HTTP $statusCode, code $code, no message.',
      statusCode: statusCode,
      unknownCode: !ApiErrorCode.isKnown(code),
    );
  }

  @override
  String toString() {
    // Spelled out rather than nested inside the interpolation: a string literal
    // inside `${}` of a same-quoted string is legal Dart, but nobody should have
    // to know that while reading an error path at 2am.
    final marker = unknownCode ? ', UNKNOWN CODE' : '';
    return 'ApiException($code$marker): $message';
  }
}

/// The stable error codes named across the endpoint register.
abstract final class ApiErrorCode {
  static const unauthenticated = 'UNAUTHENTICATED';
  static const gpsTooInaccurate = 'GPS_TOO_INACCURATE';
  static const implausibleTravel = 'IMPLAUSIBLE_TRAVEL';
  static const mockedLocationRejected = 'MOCKED_LOCATION_REJECTED';
  static const sessionAlreadyUsed = 'SESSION_ALREADY_USED';
  static const sessionExpired = 'SESSION_EXPIRED';
  static const timelineOutOfWindow = 'TIMELINE_OUT_OF_WINDOW';
  static const configVersionMismatch = 'CONFIG_VERSION_MISMATCH';
  static const sessionContextMismatch = 'SESSION_CONTEXT_MISMATCH';
  static const bboxTooLarge = 'BBOX_TOO_LARGE';
  static const unknownHex = 'UNKNOWN_HEX';
  static const radiusTooLarge = 'RADIUS_TOO_LARGE';
  static const unknownSpotType = 'UNKNOWN_SPOT_TYPE';
  static const spotTooClose = 'SPOT_TOO_CLOSE';
  static const outOfProximity = 'OUT_OF_PROXIMITY';
  static const unknownTab = 'UNKNOWN_TAB';
  static const notComplete = 'NOT_COMPLETE';
  static const alreadyClaimed = 'ALREADY_CLAIMED';
  static const attestationInvalid = 'ATTESTATION_INVALID';

  // Introduced by the count-and-verify backend, which keeps its own table in
  // `supabase/functions/_shared/responses.ts` and says the two "MUST stay in
  // sync". Each exists because a route has to say something the endpoint
  // register did not anticipate.
  static const unknownSession = 'UNKNOWN_SESSION';
  static const evidenceMalformed = 'EVIDENCE_MALFORMED';
  static const malformedRequest = 'MALFORMED_REQUEST';
  static const rateLimited = 'RATE_LIMITED';
  static const scoringFailed = 'SCORING_FAILED';
  static const internal = 'INTERNAL';

  /// Every code above. Kept adjacent to them on purpose: adding a constant
  /// without adding it here makes [isKnown] report a contract-code as unknown,
  /// which is a loud failure rather than a silent one.
  static const Set<String> all = {
    unauthenticated,
    gpsTooInaccurate,
    implausibleTravel,
    mockedLocationRejected,
    sessionAlreadyUsed,
    sessionExpired,
    timelineOutOfWindow,
    configVersionMismatch,
    sessionContextMismatch,
    bboxTooLarge,
    unknownHex,
    radiusTooLarge,
    unknownSpotType,
    spotTooClose,
    outOfProximity,
    unknownTab,
    notComplete,
    alreadyClaimed,
    attestationInvalid,
    unknownSession,
    evidenceMalformed,
    malformedRequest,
    rateLimited,
    scoringFailed,
    internal,
  };

  /// §Common rules: "Unknown codes are a contract bug — report them, don't guess
  /// at handling." This is the check that makes "report them" possible; without
  /// it the only option is a switch statement that quietly swallows anything new.
  static bool isKnown(String code) => all.contains(code);
}

// ---------------------------------------------------------------------------
// JSON coercion — the only place a wire value becomes a Dart value
// ---------------------------------------------------------------------------
//
// Two rules, both learned from the server rather than assumed:
//
//   1. NEVER `as double` on a JSON number. JSON has one number type and Dart has
//      two, so a whole-valued double arrives as an `int`. This is reachable, not
//      theoretical: a fully penalised set awards exactly 20 reps × 0.60
//      formFactor floor × 0.50 tempo floor = 6, and the backend emits
//      `{"power":6}`. `json['power'] as double` throws on that, and so does
//      every `PersonalRecord.value` for a max-reps PR.
//   2. A malformed payload throws `FormatException` naming the field. A bare
//      "type 'int' is not a subtype of type 'double' in type cast" is not
//      debuggable on stage; "hexResult.power: expected a number, got String
//      (null)" is.

FormatException _bad(String field, Object? value, String want) =>
    FormatException(
      '$field: expected $want, got ${value.runtimeType} ($value)',
    );

Map<String, Object?> _asMap(Object? json, String field) {
  if (json is Map<String, Object?>) return json;
  if (json is Map) return Map<String, Object?>.from(json);
  throw _bad(field, json, 'an object');
}

Map<String, Object?>? _asMapOrNull(Object? json, String field) =>
    json == null ? null : _asMap(json, field);

List<Object?> _asList(Object? json, String field) {
  if (json is List<Object?>) return json;
  if (json is List) return List<Object?>.from(json);
  throw _bad(field, json, 'an array');
}

List<String> _asStringList(Object? json, String field) => _asList(
  json,
  field,
).map((e) => _asString(e, '$field[]')).toList(growable: false);

double _asDouble(Object? json, String field) {
  if (json is double) return json;
  if (json is int) return json.toDouble();
  throw _bad(field, json, 'a number');
}

/// Whole numbers only, and a fractional value is an error rather than a silent
/// truncation — `xp: 6.5` means the server broke its own `Math.round`, and
/// rounding it away here would hide that.
int _asInt(Object? json, String field) {
  if (json is int) return json;
  if (json is double && json == json.roundToDouble()) return json.round();
  throw _bad(field, json, 'a whole number');
}

String _asString(Object? json, String field) {
  if (json is String) return json;
  throw _bad(field, json, 'a string');
}

String? _asStringOrNull(Object? json, String field) =>
    json == null ? null : _asString(json, field);

bool _asBool(Object? json, String field) {
  if (json is bool) return json;
  throw _bad(field, json, 'a boolean');
}

/// For the flags the server defaults rather than requires. `isMocked` and
/// `voided` are both read this way because `parseStartRequest` treats a missing
/// `isMocked` as `false` — a client that demanded the key would fail to read its
/// own request echoed back.
bool _asBoolOr(Object? json, String field, bool fallback) =>
    json == null ? fallback : _asBool(json, field);

// ---------------------------------------------------------------------------
// Geo — plain coordinates; H3 is computed server-side (requirements.md §8)
// ---------------------------------------------------------------------------

@immutable
class GeoPoint {
  const GeoPoint({required this.lat, required this.lng});

  final double lat;
  final double lng;
}

/// A hex boundary shipped as plain coordinates — the client never computes H3.
typedef HexPolygon = List<GeoPoint>;

// ---------------------------------------------------------------------------
// Sessions — POST /session/start, POST /session/submit
// ---------------------------------------------------------------------------

/// The location block of `POST /session/start` and spot check-in requests.
@immutable
class SessionLocation {
  const SessionLocation({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    this.isMocked = false,
  });

  final double lat;
  final double lng;
  final double accuracyM;
  final bool isMocked;

  /// The `location` block of a `POST /session/start` request body, whose full
  /// shape is `{ "location": {...}, "spotId": null }` (§endpoints).
  Map<String, Object?> toJson() => <String, Object?>{
    'lat': lat,
    'lng': lng,
    'accuracyM': accuracyM,
    'isMocked': isMocked,
  };

  factory SessionLocation.fromJson(Object? json) {
    final map = _asMap(json, 'location');
    return SessionLocation(
      lat: _asDouble(map['lat'], 'location.lat'),
      lng: _asDouble(map['lng'], 'location.lng'),
      accuracyM: _asDouble(map['accuracyM'], 'location.accuracyM'),
      isMocked: _asBoolOr(map['isMocked'], 'location.isMocked', false),
    );
  }
}

/// Response of `POST /session/start` — the session-start context that submit
/// must match and that territory always resolves from (§session lifecycle).
@immutable
class SessionStart {
  const SessionStart({
    required this.sessionId,
    required this.serverStartMs,
    required this.movementConfigVersion,
    required this.hexH3,
    required this.expiresAtMs,
    this.spotId,
  });

  final String sessionId;
  final int serverStartMs;

  /// The frozen threshold/config version bound to this session; submit must
  /// echo it back or be rejected with `CONFIG_VERSION_MISMATCH`.
  final String movementConfigVersion;

  final String hexH3;
  final String? spotId;
  final int expiresAtMs;

  /// Reads the `POST /session/start` response.
  ///
  /// `serverStartMs` and `expiresAtMs` are the only two absolute epoch values the
  /// client ever receives — every `*Ms` inside Evidence is an OFFSET from session
  /// start, which is what makes the wall-clock check immune to a spoofed client
  /// clock (I3). Do not mix the two conventions.
  factory SessionStart.fromJson(Object? json) {
    final map = _asMap(json, 'session/start response');
    return SessionStart(
      sessionId: _asString(map['sessionId'], 'sessionId'),
      serverStartMs: _asInt(map['serverStartMs'], 'serverStartMs'),
      movementConfigVersion: _asString(
        map['movementConfigVersion'],
        'movementConfigVersion',
      ),
      hexH3: _asString(map['hexH3'], 'hexH3'),
      spotId: _asStringOrNull(map['spotId'], 'spotId'),
      expiresAtMs: _asInt(map['expiresAtMs'], 'expiresAtMs'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'serverStartMs': serverStartMs,
    'movementConfigVersion': movementConfigVersion,
    'hexH3': hexH3,
    'spotId': spotId,
    'expiresAtMs': expiresAtMs,
  };
}

/// Consequence sub-records of a submission. The contract names the top-level
/// fields; these are their minimal typed payloads.
@immutable
class HexResult {
  const HexResult({
    required this.h3,
    required this.captured,
    required this.power,
    required this.yourPower,
  });

  final String h3;
  final bool captured;
  final double power;
  final double yourPower;

  factory HexResult.fromJson(Object? json) {
    final map = _asMap(json, 'hexResult');
    return HexResult(
      h3: _asString(map['h3'], 'hexResult.h3'),
      captured: _asBool(map['captured'], 'hexResult.captured'),
      power: _asDouble(map['power'], 'hexResult.power'),
      yourPower: _asDouble(map['yourPower'], 'hexResult.yourPower'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'h3': h3,
    'captured': captured,
    'power': power,
    'yourPower': yourPower,
  };
}

@immutable
class SpotResult {
  const SpotResult({
    required this.spotId,
    required this.captured,
    required this.rank,
  });

  final String spotId;
  final bool captured;
  final int rank;

  factory SpotResult.fromJson(Object? json) {
    final map = _asMap(json, 'spotResult');
    return SpotResult(
      spotId: _asString(map['spotId'], 'spotResult.spotId'),
      captured: _asBool(map['captured'], 'spotResult.captured'),
      rank: _asInt(map['rank'], 'spotResult.rank'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'spotId': spotId,
    'captured': captured,
    'rank': rank,
  };
}

@immutable
class RankChange {
  const RankChange({required this.before, required this.after});

  final int before;
  final int after;

  factory RankChange.fromJson(Object? json) {
    final map = _asMap(json, 'rankChange');
    return RankChange(
      before: _asInt(map['before'], 'rankChange.before'),
      after: _asInt(map['after'], 'rankChange.after'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'before': before,
    'after': after,
  };
}

@immutable
class PersonalRecord {
  const PersonalRecord({
    required this.movementId,
    required this.metric,
    required this.value,
  });

  final String movementId;

  /// max reps / max hold / hardest tier (requirements.md E5).
  final String metric;
  final double value;

  factory PersonalRecord.fromJson(Object? json) {
    final map = _asMap(json, 'prs[]');
    return PersonalRecord(
      movementId: _asString(map['movementId'], 'prs[].movementId'),
      metric: _asString(map['metric'], 'prs[].metric'),
      value: _asDouble(map['value'], 'prs[].value'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'movementId': movementId,
    'metric': metric,
    'value': value,
  };
}

/// Response of `POST /session/submit` — **all consequences in one response**
/// (requirements.md C4). The client never sends a score; everything here is
/// server-computed (I1).
@immutable
class SubmitResult {
  const SubmitResult({
    required this.xp,
    required this.level,
    required this.levelUps,
    required this.hexResult,
    required this.spotResult,
    required this.rankChange,
    required this.unlocks,
    required this.prs,
    required this.achievements,
    this.voided = false,
  });

  final int xp;
  final int level;
  final List<int> levelUps;
  final HexResult? hexResult;
  final SpotResult? spotResult;
  final RankChange? rankChange;

  /// Movement ids newly unlocked (variation tree, requirements.md §4).
  final List<String> unlocks;
  final List<PersonalRecord> prs;
  final List<String> achievements;
  final bool voided;

  /// Reads the C4 everything-response of `POST /session/submit`.
  ///
  /// `hexResult`, `spotResult` and `rankChange` are genuinely nullable on the
  /// wire, not merely absent when unimplemented: the backend returns `null` for a
  /// session that awarded nothing, because a hexResult carrying `power: 0` would
  /// make the summary screen celebrate a capture that did not happen. Treat null
  /// as "no territory changed" and never as a parsing failure.
  factory SubmitResult.fromJson(Object? json) {
    final map = _asMap(json, 'session/submit response');
    final hex = _asMapOrNull(map['hexResult'], 'hexResult');
    final spot = _asMapOrNull(map['spotResult'], 'spotResult');
    final rank = _asMapOrNull(map['rankChange'], 'rankChange');
    return SubmitResult(
      xp: _asInt(map['xp'], 'xp'),
      level: _asInt(map['level'], 'level'),
      levelUps: _asList(
        map['levelUps'],
        'levelUps',
      ).map((e) => _asInt(e, 'levelUps[]')).toList(growable: false),
      hexResult: hex == null ? null : HexResult.fromJson(hex),
      spotResult: spot == null ? null : SpotResult.fromJson(spot),
      rankChange: rank == null ? null : RankChange.fromJson(rank),
      unlocks: _asStringList(map['unlocks'], 'unlocks'),
      prs: _asList(
        map['prs'],
        'prs',
      ).map((e) => PersonalRecord.fromJson(e)).toList(growable: false),
      achievements: _asStringList(map['achievements'], 'achievements'),
      voided: _asBoolOr(map['voided'], 'voided', false),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'xp': xp,
    'level': level,
    'levelUps': levelUps,
    'hexResult': hexResult?.toJson(),
    'spotResult': spotResult?.toJson(),
    'rankChange': rankChange?.toJson(),
    'unlocks': unlocks,
    'prs': prs.map((p) => p.toJson()).toList(growable: false),
    'achievements': achievements,
    'voided': voided,
  };
}

// ---------------------------------------------------------------------------
// Territory — GET /territory/*
// ---------------------------------------------------------------------------

@immutable
class HexCell {
  const HexCell({
    required this.h3,
    required this.polygon,
    required this.ownerColor,
    required this.power,
    required this.yours,
    this.ownerHandle,
  });

  final String h3;
  final HexPolygon polygon;
  final String? ownerHandle;
  final String ownerColor;
  final double power;
  final bool yours;
}

@immutable
class HexFlip {
  const HexFlip({required this.handle, required this.atMs});

  final String handle;
  final int atMs;
}

@immutable
class HexDetail {
  const HexDetail({
    required this.h3,
    required this.power,
    required this.yourPower,
    required this.spots,
    required this.recentFlips,
    this.ownerHandle,
  });

  final String h3;
  final String? ownerHandle;
  final double power;
  final double yourPower;
  final List<SpotSummary> spots;
  final List<HexFlip> recentFlips;
}

@immutable
class LeaderboardRow {
  const LeaderboardRow({
    required this.rank,
    required this.handle,
    required this.hexesHeld,
    required this.areaKm2,
  });

  final int rank;
  final String handle;
  final int hexesHeld;
  final double areaKm2;
}

// ---------------------------------------------------------------------------
// Spots — GET/POST /spots/*
// ---------------------------------------------------------------------------

/// Spot types from requirements.md §3.
enum SpotType {
  calisthenicsPark('calisthenics_park'),
  gym('gym'),
  pullUpBar('pull_up_bar'),
  playground('playground'),
  custom('custom');

  const SpotType(this.wireName);

  final String wireName;
}

@immutable
class SpotSummary {
  const SpotSummary({
    required this.id,
    required this.name,
    required this.type,
    required this.lat,
    required this.lng,
    required this.verified,
    this.holderHandle,
    this.distanceM,
  });

  final String id;
  final String name;
  final SpotType type;
  final double lat;
  final double lng;

  /// User-created spots stay unverified until 3 distinct users train there
  /// (requirements.md E6).
  final bool verified;
  final String? holderHandle;
  final double? distanceM;
}

@immutable
class CheckInResult {
  const CheckInResult({required this.checkedIn, required this.spotId});

  final bool checkedIn;
  final String spotId;
}

/// Board tabs (requirements.md E4).
enum BoardTab {
  power('power'),
  pr('pr'),
  achievements('achievements');

  const BoardTab(this.wireName);

  final String wireName;
}

@immutable
class BoardRow {
  const BoardRow({
    required this.rank,
    required this.handle,
    required this.value,
  });

  final int rank;
  final String handle;
  final double value;
}

// ---------------------------------------------------------------------------
// Progression — GET /me, GET /movements
// ---------------------------------------------------------------------------

@immutable
class UserProfile {
  const UserProfile({
    required this.handle,
    required this.level,
    required this.xp,
    required this.lifetimeRepScore,
    required this.unlockedTiers,
    this.avatarUrl,
    this.homeSpotId,
  });

  final String handle;
  final String? avatarUrl;
  final int level;
  final int xp;
  final double lifetimeRepScore;
  final String? homeSpotId;
  final List<String> unlockedTiers;
}

/// Measurement types (api-contract.md §evidence · Two measurement types).
enum MeasurementType {
  repBodyweight('repBodyweight'),
  holdTime('holdTime');

  const MeasurementType(this.wireName);

  final String wireName;
}

/// Movement families — the variation tree (requirements.md §4).
enum MovementFamily {
  squat('squat'),
  push('push'),
  pull('pull'),
  hold('hold'),
  jump('jump');

  const MovementFamily(this.wireName);

  final String wireName;
}

@immutable
class Movement {
  const Movement({
    required this.id,
    required this.family,
    required this.tier,
    required this.difficulty,
    required this.measurementType,
    required this.unlocked,
    required this.repsTowardNextTier,
  });

  final String id;
  final MovementFamily family;
  final int tier;

  /// Difficulty multiplier — frozen Day 1 (requirements.md §4).
  final double difficulty;
  final MeasurementType measurementType;
  final bool unlocked;
  final int repsTowardNextTier;
}

// ---------------------------------------------------------------------------
// Challenges — GET /challenges/daily, POST /challenges/daily/claim
// ---------------------------------------------------------------------------

@immutable
class DailyChallenge {
  const DailyChallenge({
    required this.templateId,
    required this.description,
    required this.target,
    required this.progress,
    required this.claimed,
  });

  final String templateId;
  final String description;
  final int target;

  /// Counts verified, server-scored results only. Slice 1 ships one static
  /// seeded daily challenge; missions may award capped XP only.
  final int progress;
  final bool claimed;
}

@immutable
class ChallengeClaim {
  const ChallengeClaim({required this.claimed, required this.xpAwarded});

  final bool claimed;
  final int xpAwarded;
}

// ---------------------------------------------------------------------------
// Attestation — POST /devices/attest (Day 6, I5)
// ---------------------------------------------------------------------------

@immutable
class AttestResult {
  const AttestResult({required this.bound});

  final bool bound;
}
