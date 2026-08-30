/// Typed models generated from [docs/api-contract.md](../../docs/api-contract.md) —
/// the interface all three tracks meet at (roles.md §4 Seam 1, §5).
///
/// Ownership: B. Field names mirror the endpoint register (§endpoints) and the
/// Evidence shape (§evidence) verbatim. Do not add fields that the contract
/// does not name — additive contract changes are announced in standup.
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
  });

  final String code;
  final String message;
  final int statusCode;

  @override
  String toString() => 'ApiException($code): $message';
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
}

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
}

@immutable
class RankChange {
  const RankChange({required this.before, required this.after});

  final int before;
  final int after;
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
