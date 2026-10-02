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
    // No accuracy gate (D4) here, deliberately: the demo world is played on
    // stage, usually indoors, and must never refuse a set over a weak fix.
    // The live server keeps the gate.
    final now = DateTime.now().millisecondsSinceEpoch;
    final hex = StubWorld.hexAt(location.lat, location.lng);
    StubWorld.beginSession(hex);
    return SessionStart(
      sessionId: DemoVenue.sessionId,
      serverStartMs: now,
      movementConfigVersion: DemoVenue.movementConfigVersion,
      hexH3: hex,
      spotId: spotId ?? DemoVenue.demoSpotId,
      expiresAtMs: now + const Duration(hours: 4).inMilliseconds,
    );
  }

  @override
  Future<SubmitResult> submit(Map<String, Object?> evidence) async {
    // Stub: makes the hex the session started in yours (a capture the first
    // time, power added after). The score is worked out from the set itself
    // so the summary reads true to what you just did — and it never leaves
    // the phone, so the demo cannot touch a real score. A payload with no
    // reps (the contract fixtures) gets the B-24 fixture's numbers.
    final hex = StubWorld.lastStartH3 ?? DemoVenue.demoHexH3;
    final captured = StubWorld.capture(hex);
    final set = _firstSet(evidence);
    if (set == null) {
      return SubmitResult(
        xp: 240,
        level: 3,
        levelUps: const [],
        hexResult: HexResult(
          h3: hex,
          captured: captured,
          power: 1240,
          yourPower: captured ? 620 : 1240,
        ),
        spotResult: const SpotResult(
          spotId: DemoVenue.demoSpotId,
          captured: true,
          rank: 1,
        ),
        rankChange: const RankChange(before: 4, after: 2),
        unlocks: const [],
        prs: const [
          PersonalRecord(movementId: 'squat', metric: 'max_reps', value: 20),
        ],
        achievements: const ['first_capture'],
      );
    }
    // Roughly what the server awards a clean set: reps × difficulty × a good
    // form factor, at ~1 XP per point.
    final score = (set.reps * _difficulty(set.movementId) * 9).round();
    final best = _bestReps[set.movementId] ?? 0;
    final isPr = set.reps > best;
    if (isPr) _bestReps[set.movementId] = set.reps;
    return SubmitResult(
      xp: score,
      level: 3,
      levelUps: const [],
      hexResult: HexResult(
        h3: hex,
        captured: captured,
        power: math.max(score.toDouble(), 1),
        yourPower: math.max(score.toDouble(), 1),
      ),
      spotResult: null,
      rankChange: captured ? const RankChange(before: 4, after: 3) : null,
      unlocks: const [],
      prs: [
        if (isPr)
          PersonalRecord(
            movementId: set.movementId,
            metric: 'max_reps',
            value: set.reps.toDouble(),
          ),
      ],
      achievements: const [],
    );
  }

  /// Your best demo set per movement, for the PR line.
  static final _bestReps = <String, int>{};

  static double _difficulty(String movementId) => switch (movementId) {
    'pull_up' => 2.0,
    'push_up' => 1.2,
    _ => 1.0,
  };

  static ({String movementId, int reps})? _firstSet(
    Map<String, Object?> evidence,
  ) {
    final sets = evidence['sets'];
    if (sets is! List || sets.isEmpty) return null;
    final set = sets.first;
    if (set is! Map) return null;
    final movementId = set['movementId'];
    final reps = set['reps'];
    if (movementId is! String || reps is! List || reps.isEmpty) return null;
    return (movementId: movementId, reps: reps.length);
  }
}

// ---------------------------------------------------------------------------
// Territory
// ---------------------------------------------------------------------------

/// The demo world's hex grid: a fixed lattice of pointy-top hexes the size of a
/// real H3 res-8 cell, covering the whole planet, so the demo can be played
/// wherever the phone is. Used by the OFFLINE demo (a build with no server);
/// a demo over a server draws the real map instead (`demo_repositories.dart`).
///
/// FIXED, NOT VIEWPORT-RELATIVE. A cell's id and outline depend only on where it
/// is, so the hex the map highlights, the hex a session starts in and the hex
/// the summary flashes are always the same cell, however the map was anchored.
/// The cell containing the demo venue keeps [DemoVenue.demoHexH3], the id the
/// live server gives that spot.
///
/// A LITTLE STATE, SO THE DEMO MOVES. Ownership is a fixed pattern (about a
/// third open, a fifth yours, the rest split between the seeded rivals), with two
/// overrides: the hex the map first opens in is always a rival's, so the first
/// set captures it, and every hex a set lands in becomes yours from then on.
abstract final class StubWorld {
  static const _metresPerDegree = 111320.0;

  /// Centre-to-corner, metres — about a res-8 cell's edge.
  static const radiusM = 461.0;

  static const rivals = ['rival_kat', 'iron_meridian', 'parkside_crew'];

  /// Hexes captured in the demo → whether each was already yours before.
  static final _captured = <String, bool>{};
  static String? _home;

  /// The hex the most recent demo session started in — what its submit flips.
  static String? lastStartH3;

  /// Whether that hex was already yours when the session started, when the
  /// real map said so; null means "ask the fixed pattern".
  static bool? _lastStartWasYours;

  /// Back to a fresh demo world.
  static void reset() {
    _captured.clear();
    _home = null;
    lastStartH3 = null;
    _lastStartWasYours = null;
  }

  /// A demo session opened in [h3]. [wasYours] comes from the real map when
  /// the demo is drawn over live territory.
  static void beginSession(String h3, {bool? wasYours}) {
    lastStartH3 = h3;
    _lastStartWasYours = wasYours;
  }

  /// True once a demo set has landed in [h3].
  static bool isCaptured(String h3) => _captured.containsKey(h3);

  /// Hexes the demo made yours that were not yours already.
  static int get newlyHeld => _captured.values.where((was) => !was).length;

  /// Metres per degree of longitude. Fixed per whole-degree latitude band, so
  /// the lattice tessellates exactly within a band (~111 km — any demo).
  static double _kx(double lat) =>
      math.cos((lat.floorToDouble() + .5) * math.pi / 180) * _metresPerDegree;

  static ({int q, int r}) _cellAt(double lat, double lng) {
    final x = lng * _kx(lat);
    final y = lat * _metresPerDegree;
    final qf = (math.sqrt(3) / 3 * x - y / 3) / radiusM;
    final rf = (2 / 3 * y) / radiusM;
    // Cube rounding: the nearest hex centre.
    final sf = -qf - rf;
    var q = qf.round();
    var r = rf.round();
    final s = sf.round();
    final dq = (q - qf).abs();
    final dr = (r - rf).abs();
    final ds = (s - sf).abs();
    if (dq > dr && dq > ds) {
      q = -r - s;
    } else if (dr > ds) {
      r = -q - s;
    }
    return (q: q, r: r);
  }

  static ({int q, int r}) get _venue => _cellAt(DemoVenue.lat, DemoVenue.lng);

  static String _idOf(int q, int r) {
    final venue = _venue;
    return q == venue.q && r == venue.r ? DemoVenue.demoHexH3 : 'stub_${q}_$r';
  }

  static ({int q, int r})? _parse(String id) {
    if (id == DemoVenue.demoHexH3) return _venue;
    final parts = id.split('_');
    if (parts.length != 3 || parts.first != 'stub') return null;
    final q = int.tryParse(parts[1]);
    final r = int.tryParse(parts[2]);
    return q == null || r == null ? null : (q: q, r: r);
  }

  /// The id of the hex containing a point.
  static String hexAt(double lat, double lng) {
    final cell = _cellAt(lat, lng);
    return _idOf(cell.q, cell.r);
  }

  static GeoPoint _centre(int q, int r, double kx) => GeoPoint(
    lat: radiusM * 1.5 * r / _metresPerDegree,
    lng: radiusM * math.sqrt(3) * (q + r / 2) / kx,
  );

  static List<GeoPoint> _outline(int q, int r, double kx) {
    final centre = _centre(q, r, kx);
    return [
      for (var i = 0; i < 6; i++)
        GeoPoint(
          lat:
              centre.lat +
              radiusM *
                  math.sin((60 * i - 30) * math.pi / 180) /
                  _metresPerDegree,
          lng:
              centre.lng +
              radiusM * math.cos((60 * i - 30) * math.pi / 180) / kx,
        ),
    ];
  }

  /// Who holds a hex: you, a rival, or nobody (null).
  static ({bool yours, String? owner}) holder(String id) {
    if (_captured.containsKey(id)) {
      return (yours: true, owner: StubProgressionRepository.handle);
    }
    // The venue hex is "the north end of the park": always contested, so a
    // set there is always a capture.
    if (id == _home || id == DemoVenue.demoHexH3) {
      return (yours: false, owner: rivals.first);
    }
    final cell = _parse(id);
    if (cell == null) return (yours: false, owner: null);
    final k = ((cell.q * 73856093) ^ (cell.r * 19349663)).abs() % 9;
    if (k < 3) return (yours: false, owner: null);
    if (k < 5) return (yours: true, owner: StubProgressionRepository.handle);
    return (yours: false, owner: rivals[k % rivals.length]);
  }

  static double powerOf(String id) {
    final cell = _parse(id);
    if (cell == null) return 0;
    return 180.0 + ((cell.q * 53 + cell.r * 31).abs() % 900);
  }

  /// A set landed in [id]: it is yours now. Returns whether that changed hands.
  static bool capture(String id) {
    if (_captured.containsKey(id)) return false;
    final wasYours = id == lastStartH3 && _lastStartWasYours != null
        ? _lastStartWasYours!
        : holder(id).yours;
    _captured[id] = wasYours;
    return !wasYours;
  }

  /// Every hex whose centre lies in the box.
  static List<HexCell> cellsIn({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
  }) {
    final midLat = (swLat + neLat) / 2;
    final kx = _kx(midLat);
    _home ??= hexAt(midLat, (swLng + neLng) / 2);
    final rowStep = radiusM * 1.5;
    final colStep = radiusM * math.sqrt(3);
    final rMin = (swLat * _metresPerDegree / rowStep).floor() - 1;
    final rMax = (neLat * _metresPerDegree / rowStep).ceil() + 1;
    final cells = <HexCell>[];
    for (var r = rMin; r <= rMax; r++) {
      final qMin = (swLng * kx / colStep - r / 2).floor() - 1;
      final qMax = (neLng * kx / colStep - r / 2).ceil() + 1;
      for (var q = qMin; q <= qMax; q++) {
        final centre = _centre(q, r, kx);
        if (centre.lat < swLat ||
            centre.lat > neLat ||
            centre.lng < swLng ||
            centre.lng > neLng) {
          continue;
        }
        final id = _idOf(q, r);
        final held = holder(id);
        cells.add(
          HexCell(
            h3: id,
            polygon: _outline(q, r, kx),
            ownerHandle: held.owner,
            ownerColor: held.yours
                ? 'mine'
                : held.owner == null
                ? 'unclaimed'
                : 'rival',
            power: held.owner == null ? 0 : powerOf(id),
            yours: held.yours,
          ),
        );
      }
    }
    return cells;
  }

  /// True for an id this world could have issued.
  static bool knows(String id) => _parse(id) != null;
}

class StubTerritoryRepository implements TerritoryRepository {
  const StubTerritoryRepository();

  @override
  Future<List<HexCell>> hexes({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
  }) async {
    // H3 boundaries are computed by the live Edge Function. The Flutter stub
    // cannot import the server-only H3 package, so it draws [StubWorld]'s
    // lattice with the same wire shape and ownership semantics.
    return StubWorld.cellsIn(
      swLat: swLat,
      swLng: swLng,
      neLat: neLat,
      neLng: neLng,
    );
  }

  @override
  Future<HexDetail> hexDetail(String h3) async {
    if (!StubWorld.knows(h3)) {
      throw const ApiException(
        code: ApiErrorCode.unknownHex,
        message: 'Unknown hex index.',
        statusCode: 404,
      );
    }
    final held = StubWorld.holder(h3);
    final power = StubWorld.powerOf(h3);
    final rival = held.yours ? StubWorld.rivals.first : held.owner;
    return HexDetail(
      h3: h3,
      ownerHandle: held.owner,
      power: power,
      yourPower: held.yours ? power : power / 2,
      spots: h3 == DemoVenue.demoHexH3
          ? StubSpotsRepository.seedSpots
          : const [],
      recentFlips: [
        if (rival != null)
          HexFlip(
            handle: rival,
            atMs: DateTime.now()
                .subtract(const Duration(hours: 5))
                .millisecondsSinceEpoch,
          ),
        HexFlip(
          handle: StubProgressionRepository.handle,
          atMs: DateTime.now()
              .subtract(const Duration(hours: 26))
              .millisecondsSinceEpoch,
        ),
      ],
    );
  }

  @override
  Future<List<LeaderboardRow>> leaderboard() async {
    // Stub: a seeded 10-row board with you climbing it as you capture.
    final rows = [
      (handle: 'iron_meridian', hexes: 9),
      (handle: 'rival_kat', hexes: 7),
      (handle: 'parkside_crew', hexes: 6),
      (
        handle: StubProgressionRepository.handle,
        hexes: 5 + StubWorld.newlyHeld,
      ),
      (handle: 'north_bar_owl', hexes: 4),
      (handle: 'plank_pilgrim', hexes: 3),
      (handle: 'dip_machine', hexes: 3),
      (handle: 'muscle_up_mo', hexes: 2),
      (handle: 'sunrise_squat', hexes: 1),
      (handle: 'slow_burn', hexes: 1),
    ]..sort((a, b) => b.hexes.compareTo(a.hexes));
    return [
      for (var i = 0; i < rows.length; i++)
        LeaderboardRow(
          rank: i + 1,
          handle: rows[i].handle,
          hexesHeld: rows[i].hexes,
          // Res-8 cells average ~0.74 km².
          areaKm2: (rows[i].hexes * 0.737 * 10).roundToDouble() / 10,
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
    // The seeded spots, laid out around wherever the demo is being played:
    // the rig a stone's throw away, the others a short walk.
    final origin = seedSpots.first;
    return [
      for (final spot in seedSpots)
        SpotSummary(
          id: spot.id,
          name: spot.name,
          type: spot.type,
          lat: lat + (spot.lat - origin.lat) + .0006,
          lng: lng + (spot.lng - origin.lng) + .0004,
          verified: spot.verified,
          holderHandle: spot.holderHandle,
          distanceM: distanceM(
            lat,
            lng,
            lat + (spot.lat - origin.lat) + .0006,
            lng + (spot.lng - origin.lng) + .0004,
          ),
        ),
    ];
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
  StubPresenceRepository({this.cellsAround});

  /// The hexes around a fix to put the scripted athletes in. Demo over live
  /// territory passes the real grid, so they stand in real hexes; null uses
  /// the offline demo world's.
  final Future<List<HexCell>> Function(SessionLocation location)? cellsAround;

  /// The last grid fetched, reused until you move a few hundred metres — a
  /// heartbeat every 15 s should not refetch the map each time.
  ({SessionLocation at, List<HexCell> cells})? _grid;

  Future<List<HexCell>> _cells(SessionLocation location) async {
    final grid = _grid;
    if (grid != null &&
        distanceM(grid.at.lat, grid.at.lng, location.lat, location.lng) < 300) {
      return grid.cells;
    }
    final fetch = cellsAround;
    final cells = fetch != null
        ? await fetch(location)
        : await const StubTerritoryRepository().hexes(
            swLat: location.lat - .02,
            swLng: location.lng - .02,
            neLat: location.lat + .02,
            neLng: location.lng + .02,
          );
    _grid = (at: location, cells: cells);
    return cells;
  }

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
    // The same grid the map draws around this fix, so each player sits in
    // the centre of a visible hex.
    final cells = await _cells(location);
    if (cells.length <= _cellRanks.last) return const [];
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
