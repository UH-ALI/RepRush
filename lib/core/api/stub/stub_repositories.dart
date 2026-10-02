/// Stub repositories — realistic fake data, per api-contract.md §endpoints
/// ("Stubs: return populated, realistic data — contested hexes, non-empty
/// boards, a plausible unlock — never empty arrays"). C builds every screen
/// against these until B swaps in live Supabase repositories (roles.md Seam 2).
///
/// Ownership: B.
library;

import 'dart:math' as math;

import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/location/geo.dart';
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
    // H3 boundaries are computed by the live Edge Function. The Flutter stub
    // cannot import the server-only H3 package, so it uses a tessellating
    // pointy-hex fixture with the same wire shape and ownership semantics.
    const rows = 10;
    const cols = 9;
    final cellWidth = math.max(0.001, (neLng - swLng) / cols);
    final radiusLng = cellWidth / math.sqrt(3);
    final radiusLat = (neLat - swLat) / (rows * 1.5);
    final cells = <HexCell>[];
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final i = r * cols + c;
        final centerLat =
            swLat +
            radiusLat +
            r * radiusLat * 1.5 +
            (c.isOdd ? radiusLat * .75 : 0);
        final centerLng = swLng + radiusLng + c * cellWidth;
        final polygon = <GeoPoint>[
          GeoPoint(lat: centerLat + radiusLat, lng: centerLng),
          GeoPoint(lat: centerLat + radiusLat / 2, lng: centerLng + radiusLng),
          GeoPoint(lat: centerLat - radiusLat / 2, lng: centerLng + radiusLng),
          GeoPoint(lat: centerLat - radiusLat, lng: centerLng),
          GeoPoint(lat: centerLat - radiusLat / 2, lng: centerLng - radiusLng),
          GeoPoint(lat: centerLat + radiusLat / 2, lng: centerLng - radiusLng),
        ];
        final yours = i == 12;
        final owner = yours
            ? _ownerYou
            : (i % 3 == 0 ? null : _owners[i % _owners.length]);
        cells.add(
          HexCell(
            h3: yours
                ? DemoVenue.demoHexH3
                : '88195da49bf${(i + 1).toRadixString(16).padLeft(4, '0')}',
            polygon: polygon,
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
// Account
// ---------------------------------------------------------------------------

/// In-memory accounts: any email/password pair "exists" once saved, and
/// a password starting `wrong` always fails, so the error path is reachable.
class StubAccountRepository implements AccountRepository {
  AccountState _state = const AccountState.guest();

  @override
  Future<AccountState> current() async => _state;

  @override
  Future<AccountState> saveProgress({
    required String email,
    required String password,
  }) async => _state = AccountState.signedIn(email);

  @override
  Future<AccountState> logIn({
    required String email,
    required String password,
  }) async {
    if (password.startsWith('wrong')) {
      throw const AccountException(
        "That email and password don't match an account.",
      );
    }
    return _state = AccountState.signedIn(email);
  }

  @override
  Future<AccountState> logOut() async => _state = const AccountState.guest();
}

// ---------------------------------------------------------------------------
// Progression
// ---------------------------------------------------------------------------

class StubProgressionRepository implements ProgressionRepository {
  const StubProgressionRepository();

  /// Process-wide so a rename survives the provider rebuilding the (const)
  /// repository.
  static String handle = 'demo_athlete';

  @override
  Future<UserProfile> me() async {
    // Stub: level 3, one unlock pending.
    return UserProfile(
      handle: handle,
      level: 3,
      xp: 540,
      lifetimeRepScore: 1240,
      homeSpotId: DemoVenue.demoSpotId,
      unlockedTiers: const ['squat_t2', 'push_up_t2', 'pull_up_t2', 'plank_t2'],
    );
  }

  @override
  Future<UserProfile> rename(String handle) async {
    final trimmed = handle.trim();
    if (trimmed.length < 3 || trimmed.length > 20) {
      throw const ApiException(
        code: ApiErrorCode.invalidHandle,
        message: 'Stub: a handle is 3-20 characters.',
        statusCode: 422,
      );
    }
    StubProgressionRepository.handle = trimmed;
    return me();
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
// Sets ledger — what the stub "server" has verified
// ---------------------------------------------------------------------------

/// The sets the stub session repository has accepted, so stub duels can score
/// your real HUD count the way the live server reads `set_records`.
abstract final class StubLedger {
  static final sets = <({String movementId, int reps, int atMs})>[];

  /// Records the one set an Evidence payload carries. Malformed input is
  /// ignored — the stub has no validator to report it to.
  static void recordEvidence(Map<String, Object?> evidence, {int? atMs}) {
    final rawSets = evidence['sets'];
    if (rawSets is! List) return;
    for (final set in rawSets) {
      if (set is! Map) continue;
      final movementId = set['movementId'];
      final reps = set['reps'];
      if (movementId is! String || reps is! List) continue;
      sets.add((
        movementId: movementId,
        reps: reps.length,
        atMs: atMs ?? DateTime.now().millisecondsSinceEpoch,
      ));
    }
  }
}

// ---------------------------------------------------------------------------
// Presence
// ---------------------------------------------------------------------------

/// Three scripted athletes who are always "out training" a hex or two from
/// wherever you are, so nearby play demos on one phone.
class StubPresenceRepository implements PresenceRepository {
  StubPresenceRepository();

  static const players = [
    (userId: 'stub-rival-kat', handle: 'rival_kat', level: 7, hexes: 7),
    (userId: 'stub-iron-meridian', handle: 'iron_meridian', level: 9, hexes: 9),
    (userId: 'stub-north-bar-owl', handle: 'north_bar_owl', level: 4, hexes: 4),
  ];

  /// Which of the cells nearest you each player stands in (0 is your own).
  static const _cellRanks = [1, 3, 5];

  bool visible = false;

  @override
  Future<List<NearbyPlayer>> heartbeat(SessionLocation location) async {
    visible = true;
    // The same fixture grid the stub map draws around this fix, so each
    // player sits in the centre of a visible hex.
    final cells = await const StubTerritoryRepository().hexes(
      swLat: location.lat - .02,
      swLng: location.lng - .02,
      neLat: location.lat + .02,
      neLng: location.lng + .02,
    );
    double away(HexCell c) {
      final centre = polygonCentre(c.polygon);
      return distanceM(location.lat, location.lng, centre.lat, centre.lng);
    }

    final nearest = [...cells]..sort((a, b) => away(a).compareTo(away(b)));
    return [
      for (var i = 0; i < players.length; i++)
        NearbyPlayer(
          userId: players[i].userId,
          handle: players[i].handle,
          level: players[i].level,
          hexesHeld: players[i].hexes,
          h3: nearest[_cellRanks[i]].h3,
          centre: polygonCentre(nearest[_cellRanks[i]].polygon),
        ),
    ];
  }

  @override
  Future<void> goInvisible() async => visible = false;
}

// ---------------------------------------------------------------------------
// Duels
// ---------------------------------------------------------------------------

class _StubDuel {
  _StubDuel({
    required this.id,
    required this.opponentId,
    required this.opponentHandle,
    required this.movementId,
    required this.createdAtMs,
    required this.theirReps,
  });

  final String id;
  final String opponentId;
  final String opponentHandle;
  final String movementId;
  final int createdAtMs;
  final int theirReps;
  bool claimed = false;
}

/// A scripted opponent: accepts a few seconds after you challenge, posts a
/// beatable set shortly after, and the duel finishes the moment your set
/// lands — the whole loop plays out on one phone. Your reps come from
/// [StubLedger], i.e. the set you actually did.
class StubDuelsRepository implements DuelsRepository {
  StubDuelsRepository({int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  final _duels = <_StubDuel>[];

  static const acceptAfterMs = 3000;
  static const theirSetAfterMs = 25000;
  static const windowMs = 10 * 60 * 1000;
  static const respondWindowMs = 5 * 60 * 1000;
  static const winXp = 100;
  static const finishXp = 25;

  /// Each scripted opponent's set — beatable on stage.
  static const _theirReps = {
    'stub-rival-kat': 10,
    'stub-iron-meridian': 14,
    'stub-north-bar-owl': 8,
  };

  Duel _view(_StubDuel d) {
    final now = _now();
    final acceptedAt = d.createdAtMs + acceptAfterMs;
    final endsAt = acceptedAt + windowMs;
    final theirs = now >= acceptedAt + theirSetAfterMs ? d.theirReps : null;
    // One set each: your first set of the movement inside the window.
    final mine = StubLedger.sets
        .where(
          (s) =>
              s.movementId == d.movementId &&
              s.atMs >= acceptedAt &&
              s.atMs < endsAt,
        )
        .firstOrNull
        ?.reps;
    final status = now < acceptedAt
        ? DuelStatus.pending
        : (mine != null && theirs != null) || now >= endsAt
        ? DuelStatus.finished
        : DuelStatus.active;
    String? result;
    if (status == DuelStatus.finished) {
      final a = mine ?? 0;
      final b = theirs ?? 0;
      result = a > b
          ? 'won'
          : a < b
          ? 'lost'
          : 'draw';
    }
    return Duel(
      id: d.id,
      movementId: d.movementId,
      opponentId: d.opponentId,
      opponentHandle: d.opponentHandle,
      incoming: false,
      status: status,
      respondByMs: d.createdAtMs + respondWindowMs,
      endsAtMs: status == DuelStatus.pending ? null : endsAt,
      myReps: mine,
      theirReps: theirs,
      result: result,
      xpReward: mine == null
          ? 0
          : result == 'won'
          ? winXp
          : finishXp,
      claimed: d.claimed,
    );
  }

  @override
  Future<List<Duel>> list() async => [
    for (final d in _duels.reversed) _view(d),
  ];

  @override
  Future<Duel> challenge({
    required String opponentId,
    required String movementId,
  }) async {
    final opponent = StubPresenceRepository.players
        .where((p) => p.userId == opponentId)
        .firstOrNull;
    if (opponent == null) {
      throw const ApiException(
        code: ApiErrorCode.notNearby,
        message: 'Opponent is not visible near you.',
        statusCode: 409,
      );
    }
    if (_duels.any((d) => d.opponentId == opponentId && _view(d).open)) {
      throw const ApiException(
        code: ApiErrorCode.duelAlreadyOpen,
        message: 'A duel with this athlete is already open.',
        statusCode: 409,
      );
    }
    final duel = _StubDuel(
      id: 'stub-duel-${_duels.length + 1}',
      opponentId: opponentId,
      opponentHandle: opponent.handle,
      movementId: movementId,
      createdAtMs: _now(),
      theirReps: _theirReps[opponentId] ?? 10,
    );
    _duels.add(duel);
    return _view(duel);
  }

  @override
  Future<Duel> respond(String duelId, {required bool accept}) async {
    // Every stub duel is outgoing; the scripted opponent does the answering.
    throw const ApiException(
      code: ApiErrorCode.unknownDuel,
      message: 'No incoming duel with that id.',
      statusCode: 404,
    );
  }

  @override
  Future<ChallengeClaim> claim(String duelId) async {
    final duel = _duels.where((d) => d.id == duelId).firstOrNull;
    if (duel == null) {
      throw const ApiException(
        code: ApiErrorCode.unknownDuel,
        message: 'No duel with that id.',
        statusCode: 404,
      );
    }
    if (duel.claimed) {
      throw const ApiException(
        code: ApiErrorCode.alreadyClaimed,
        message: 'Duel reward already claimed.',
        statusCode: 409,
      );
    }
    final view = _view(duel);
    if (!view.canClaim) {
      throw const ApiException(
        code: ApiErrorCode.duelClosed,
        message: 'Duel not finished, or no set to reward.',
        statusCode: 409,
      );
    }
    duel.claimed = true;
    return ChallengeClaim(claimed: true, xpAwarded: view.xpReward);
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
