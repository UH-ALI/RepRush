/// Stub repositories — realistic fake data, per api-contract.md §endpoints
/// ("Stubs: return populated, realistic data — contested hexes, non-empty
/// boards, a plausible unlock — never empty arrays"). C builds every screen
/// against these until B swaps in live Supabase repositories (roles.md Seam 2).
///
/// Ownership: B.
library;

import 'dart:math' as math;

import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/models/models.dart';

/// The seeded demo venue — "the north end of the park" (requirements.md §5).
///
/// [demoHexH3] is the REAL resolution-8 cell for [lat]/[lng]: computed with h3-js
/// and cross-checked against what the live `session-start` route returns for the
/// same coordinates. It replaced a fabricated literal that turned out to be
/// resolution 10 — an invented index does not even land in the resolution you
/// meant, which is why this one is computed. It must stay equal to `VENUE.hexH3`
/// in `supabase/functions/_shared/stubs/venue.ts`; `test/models_test.dart` pins
/// the two against each other.
abstract final class DemoVenue {
  static const lat = 51.5074;
  static const lng = -0.1278;
  static const demoHexH3 = '88195da49bfffff';
  static const demoSpotId = 'spot_riverside_rig';
  static const movementConfigVersion = '2026-08-30.1';
  static const sessionId = '00000000-0000-4000-8000-000000000001';
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

class StubSessionRepository implements SessionRepository {
  const StubSessionRepository();

  @override
  Future<SessionStart> start({
    required SessionLocation location,
    String? spotId,
  }) async {
    // The demo sandbox: mocked GPS is rejected for production accounts (I7).
    if (location.isMocked) {
      throw const ApiException(
        code: ApiErrorCode.mockedLocationRejected,
        message:
            'Mocked location rejected for production accounts. Demo context '
            'is decided server-side from an allowlisted demo account (J7).',
      );
    }
    if (location.accuracyM > 50) {
      throw const ApiException(
        code: ApiErrorCode.gpsTooInaccurate,
        message: 'GPS accuracy above 50 m — territory credit needs a fix (D4).',
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    return SessionStart(
      sessionId: DemoVenue.sessionId,
      serverStartMs: now,
      movementConfigVersion: DemoVenue.movementConfigVersion,
      hexH3: DemoVenue.demoHexH3,
      spotId: spotId ?? DemoVenue.demoSpotId,
      expiresAtMs: now + const Duration(hours: 4).inMilliseconds,
    );
  }

  @override
  Future<SubmitResult> submit(Map<String, Object?> evidence) async {
    // Stub: scores the B-24 fixture, flips the seeded hex, returns one PR and
    // one rank change (api-contract.md §endpoints · POST /session/submit).
    return const SubmitResult(
      xp: 240,
      level: 3,
      levelUps: [],
      hexResult: HexResult(
        h3: DemoVenue.demoHexH3,
        captured: true,
        power: 1240,
        yourPower: 620,
      ),
      spotResult: SpotResult(
        spotId: DemoVenue.demoSpotId,
        captured: true,
        rank: 1,
      ),
      rankChange: RankChange(before: 4, after: 2),
      unlocks: [],
      prs: [PersonalRecord(movementId: 'squat', metric: 'max_reps', value: 20)],
      achievements: ['first_capture'],
    );
  }
}

// ---------------------------------------------------------------------------
// Territory
// ---------------------------------------------------------------------------

class StubTerritoryRepository implements TerritoryRepository {
  const StubTerritoryRepository();

  static const _ownerYou = 'demo_athlete';
  static const _owners = ['rival_kat', 'iron_meridian', 'parkside_crew'];

  @override
  Future<List<HexCell>> hexes({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
  }) async {
    // ~40 seeded hexes around the venue, mixed ownership. Placeholder
    // rectangular cells on a jittered grid — real H3 boundary polygons come
    // from the server (B-10).
    //
    // The ids are placeholders too, and only the `yours` cell is real: bumping
    // the trailing digits of an index does not walk to a neighbouring cell. They
    // are still res-8-SHAPED on purpose — a res-10-looking id would render fine
    // here and then 404 against a live `/territory/hex/:h3`, which is a bug that
    // only appears on the Day-3 swap. `yours` carries [DemoVenue.demoHexH3] so
    // the cell the map highlights is one `hexDetail` can actually answer for.
    const rows = 8;
    const cols = 5;
    final dLat = math.max(0.001, (neLat - swLat) / rows);
    final dLng = math.max(0.001, (neLng - swLng) / cols);
    final cells = <HexCell>[];
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final i = r * cols + c;
        final jitter = ((i * 37) % 10) / 4000.0;
        final sw = GeoPoint(
          lat: swLat + r * dLat + jitter,
          lng: swLng + c * dLng + jitter,
        );
        final ne = GeoPoint(lat: sw.lat + dLat * 0.9, lng: sw.lng + dLng * 0.9);
        final yours = i == 12;
        final owner = yours
            ? _ownerYou
            : (i % 3 == 0 ? null : _owners[i % _owners.length]);
        cells.add(
          HexCell(
            h3: yours
                ? DemoVenue.demoHexH3
                : '88195da49bf${(i + 1).toRadixString(16).padLeft(4, '0')}',
            polygon: [
              GeoPoint(lat: sw.lat, lng: sw.lng),
              GeoPoint(lat: ne.lat, lng: sw.lng),
              GeoPoint(lat: ne.lat, lng: ne.lng),
              GeoPoint(lat: sw.lat, lng: ne.lng),
            ],
            ownerHandle: owner,
            ownerColor: yours
                ? 'mine'
                : owner == null
                ? 'unclaimed'
                : 'rival',
            power: 180.0 + ((i * 53) % 900),
            yours: yours,
          ),
        );
      }
    }
    return cells;
  }

  @override
  Future<HexDetail> hexDetail(String h3) async {
    // Stub: one contested hex with two flips and one spot inside.
    if (h3 != DemoVenue.demoHexH3) {
      throw const ApiException(
        code: ApiErrorCode.unknownHex,
        message: 'Unknown hex index.',
        statusCode: 404,
      );
    }
    return HexDetail(
      h3: h3,
      ownerHandle: _owners.first,
      power: 1240,
      yourPower: 620,
      spots: StubSpotsRepository.seedSpots,
      recentFlips: [
        HexFlip(
          handle: _owners.first,
          atMs: DateTime.now()
              .subtract(const Duration(hours: 5))
              .millisecondsSinceEpoch,
        ),
        HexFlip(
          handle: _ownerYou,
          atMs: DateTime.now()
              .subtract(const Duration(hours: 26))
              .millisecondsSinceEpoch,
        ),
      ],
    );
  }

  @override
  Future<List<LeaderboardRow>> leaderboard() async {
    // Stub: a seeded 10-row board with the demo user climbing it.
    const rows = [
      (handle: 'iron_meridian', hexes: 9, area: 6.7),
      (handle: 'rival_kat', hexes: 7, area: 5.2),
      (handle: 'parkside_crew', hexes: 6, area: 4.5),
      (handle: 'demo_athlete', hexes: 5, area: 3.7),
      (handle: 'north_bar_owl', hexes: 4, area: 3.0),
      (handle: 'plank_pilgrim', hexes: 3, area: 2.2),
      (handle: 'dip_machine', hexes: 3, area: 2.2),
      (handle: 'muscle_up_mo', hexes: 2, area: 1.5),
      (handle: 'sunrise_squat', hexes: 1, area: 0.7),
      (handle: 'slow_burn', hexes: 1, area: 0.7),
    ];
    return [
      for (var i = 0; i < rows.length; i++)
        LeaderboardRow(
          rank: i + 1,
          handle: rows[i].handle,
          hexesHeld: rows[i].hexes,
          areaKm2: rows[i].area,
        ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Spots
// ---------------------------------------------------------------------------

class StubSpotsRepository implements SpotsRepository {
  const StubSpotsRepository();

  /// The seeded venue spots — one held, one open (api-contract.md §endpoints).
  static const seedSpots = [
    SpotSummary(
      id: DemoVenue.demoSpotId,
      name: 'Riverside Calisthenics Rig',
      type: SpotType.calisthenicsPark,
      lat: DemoVenue.lat,
      lng: DemoVenue.lng,
      verified: true,
      holderHandle: 'rival_kat',
      distanceM: 40,
    ),
    SpotSummary(
      id: 'spot_northgate_gym',
      name: 'PureGym Northgate',
      type: SpotType.gym,
      lat: DemoVenue.lat + 0.004,
      lng: DemoVenue.lng + 0.002,
      verified: true,
      holderHandle: null,
      distanceM: 480,
    ),
    SpotSummary(
      id: 'spot_bridge_bar',
      name: 'Bridge Pull-up Bar',
      type: SpotType.pullUpBar,
      lat: DemoVenue.lat - 0.002,
      lng: DemoVenue.lng + 0.005,
      verified: false,
      holderHandle: null,
      distanceM: 610,
    ),
  ];

  @override
  Future<List<SpotSummary>> nearby({
    required double lat,
    required double lng,
    double radiusM = 1000,
  }) async {
    if (radiusM > 2000) {
      throw const ApiException(
        code: ApiErrorCode.radiusTooLarge,
        message: 'radiusM must be <= 2000.',
      );
    }
    return seedSpots;
  }

  @override
  Future<SpotSummary> create({
    required String name,
    required SpotType type,
    required double lat,
    required double lng,
  }) async {
    // Always unverified (E6) — earns nothing until 3 distinct users train here.
    return SpotSummary(
      id: 'spot_user_${name.hashCode.abs()}',
      name: name,
      type: type,
      lat: lat,
      lng: lng,
      verified: false,
    );
  }

  @override
  Future<CheckInResult> checkIn({
    required String spotId,
    required SessionLocation location,
  }) async {
    if (location.isMocked) {
      throw const ApiException(
        code: ApiErrorCode.mockedLocationRejected,
        message:
            'Mocked location rejected for production accounts. Demo accounts '
            'may check in only at the fixed seeded demo spot (J7).',
      );
    }
    final spot = seedSpots.where((s) => s.id == spotId).firstOrNull;
    if (spot == null ||
        (spot.distanceM ?? 0) > 100 && spot.id != DemoVenue.demoSpotId) {
      throw const ApiException(
        code: ApiErrorCode.outOfProximity,
        message: 'More than 100 m from the spot (E2).',
      );
    }
    return CheckInResult(checkedIn: true, spotId: spotId);
  }

  @override
  Future<List<BoardRow>> board(String spotId, BoardTab tab) async {
    // Stub: three populated boards, demo user mid-table.
    final values = switch (tab) {
      BoardTab.power => const <double>[980, 720, 620, 410, 180],
      BoardTab.pr => const <double>[42, 31, 20, 18, 12],
      BoardTab.achievements => const <double>[260, 220, 150, 90, 40],
    };
    const handles = [
      'rival_kat',
      'iron_meridian',
      'demo_athlete',
      'north_bar_owl',
      'slow_burn',
    ];
    return [
      for (var i = 0; i < handles.length; i++)
        BoardRow(rank: i + 1, handle: handles[i], value: values[i]),
    ];
  }
}

// ---------------------------------------------------------------------------
// Progression
// ---------------------------------------------------------------------------

class StubProgressionRepository implements ProgressionRepository {
  const StubProgressionRepository();

  @override
  Future<UserProfile> me() async {
    // Stub: level 3, one unlock pending.
    return const UserProfile(
      handle: 'demo_athlete',
      level: 3,
      xp: 540,
      lifetimeRepScore: 1240,
      homeSpotId: DemoVenue.demoSpotId,
      unlockedTiers: ['squat_t2', 'push_up_t2', 'pull_up_t2', 'plank_t2'],
    );
  }

  @override
  Future<List<Movement>> movements() async {
    // Stub: T1/T2 unlocked, pull-up at 32/50 toward wide-grip.
    return const [
      Movement(
        id: 'squat',
        family: MovementFamily.squat,
        tier: 2,
        difficulty: 1.0,
        measurementType: MeasurementType.repBodyweight,
        unlocked: true,
        repsTowardNextTier: 14,
      ),
      Movement(
        id: 'push_up',
        family: MovementFamily.push,
        tier: 2,
        difficulty: 1.0,
        measurementType: MeasurementType.repBodyweight,
        unlocked: true,
        repsTowardNextTier: 8,
      ),
      Movement(
        id: 'pull_up',
        family: MovementFamily.pull,
        tier: 2,
        difficulty: 1.8,
        measurementType: MeasurementType.repBodyweight,
        unlocked: true,
        repsTowardNextTier: 32,
      ),
      Movement(
        id: 'plank',
        family: MovementFamily.hold,
        tier: 2,
        difficulty: 1.0,
        measurementType: MeasurementType.holdTime,
        unlocked: true,
        repsTowardNextTier: 0,
      ),
      Movement(
        id: 'jumping_jack',
        family: MovementFamily.jump,
        tier: 2,
        difficulty: 0.8,
        measurementType: MeasurementType.repBodyweight,
        unlocked: true,
        repsTowardNextTier: 0,
      ),
    ];
  }
}

// ---------------------------------------------------------------------------
// Challenges
// ---------------------------------------------------------------------------

class StubChallengesRepository implements ChallengesRepository {
  StubChallengesRepository({this.progress = 20});

  /// Mutable stub state so tests can drive the claim flow. Progress counts
  /// verified, server-scored results only.
  int progress;
  bool claimed = false;

  @override
  Future<DailyChallenge> daily() async {
    // Stub: "50 squat reps today", 20/50. Slice 1 ships one static seeded
    // daily challenge, identical for everyone.
    return DailyChallenge(
      templateId: 'daily-2026-08-30',
      description: '50 squat reps today',
      target: 50,
      progress: progress.clamp(0, 50),
      claimed: claimed,
    );
  }

  @override
  Future<ChallengeClaim> claimDaily() async {
    if (claimed) {
      throw const ApiException(
        code: ApiErrorCode.alreadyClaimed,
        message: 'Daily challenge already claimed.',
        statusCode: 409,
      );
    }
    if (progress < 50) {
      throw ApiException(
        code: ApiErrorCode.notComplete,
        message: 'Challenge not complete: $progress/50.',
        statusCode: 409,
      );
    }
    claimed = true;
    // Missions may award capped XP only — never territory power.
    return const ChallengeClaim(claimed: true, xpAwarded: 150);
  }
}

// ---------------------------------------------------------------------------
// Attestation
// ---------------------------------------------------------------------------

class StubDeviceAttestationRepository implements DeviceAttestationRepository {
  const StubDeviceAttestationRepository();

  @override
  Future<AttestResult> attest({
    required String platform,
    required String attestationPayload,
  }) async {
    // Stub: returns bound:false until B-19 lands (Day 6, I5).
    return const AttestResult(bound: false);
  }
}
