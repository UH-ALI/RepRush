/// Repository interfaces — the only layer allowed to touch an API backend
/// (api-contract.md §state rule 2: repositories wrap all API access; the UI
/// never calls Supabase directly).
///
/// Ownership: B. One interface per contract area; method sets mirror the
/// endpoint register in roles.md §4 Seam 2 exactly. No invented endpoints.
library;

import 'package:reprush/models/models.dart';

/// `POST /session/start`, `POST /session/submit`.
abstract interface class SessionRepository {
  /// Opens a one-shot session (I2) and fixes its context. Throws
  /// [ApiException] with `GPS_TOO_INACCURATE`, `IMPLAUSIBLE_TRAVEL`, or
  /// `MOCKED_LOCATION_REJECTED` (production accounts, I7).
  Future<SessionStart> start({
    required SessionLocation location,
    String? spotId,
  });

  /// Consumes the session and returns all consequences in one response (C4).
  /// [evidence] is the assembled Evidence object (api-contract.md §evidence)
  /// — opaque here because Track A's `EvidenceBuilder` owns that shape
  /// (§state rule 4). Throws `SESSION_ALREADY_USED`, `SESSION_EXPIRED`,
  /// `TIMELINE_OUT_OF_WINDOW`, `CONFIG_VERSION_MISMATCH`, or
  /// `SESSION_CONTEXT_MISMATCH`.
  Future<SubmitResult> submit(Map<String, Object?> evidence);
}

/// `GET /territory/hexes`, `GET /territory/hex/:h3`,
/// `GET /territory/leaderboard`, `GET /territory/mine`.
abstract interface class TerritoryRepository {
  /// Hexes in [bbox] = (swLat, swLng, neLat, neLng), shipped as plain
  /// coordinates — H3 is computed server-side (requirements.md §8 open-1).
  Future<List<HexCell>> hexes({
    required double swLat,
    required double swLng,
    required double neLat,
    required double neLng,
  });

  Future<HexDetail> hexDetail(String h3);

  Future<List<LeaderboardRow>> leaderboard();

  /// Every hex you hold, anywhere in the world, with its outline — a few
  /// dozen at most, so the map can always draw your territory without loading
  /// the grid around each piece of it.
  Future<List<HexCell>> myHexes();
}

/// `GET /spots/nearby`, `POST /spots`, `POST /spots/:id/checkin`,
/// `GET /spots/:id/board`.
abstract interface class SpotsRepository {
  Future<List<SpotSummary>> nearby({
    required double lat,
    required double lng,
    double radiusM = 1000,
  });

  /// Creates a user spot — always unverified (E6). Throws `UNKNOWN_SPOT_TYPE`
  /// or `SPOT_TOO_CLOSE`.
  Future<SpotSummary> create({
    required String name,
    required SpotType type,
    required double lat,
    required double lng,
  });

  /// Throws `OUT_OF_PROXIMITY` (>100 m, E2), `GPS_TOO_INACCURATE`, or
  /// `MOCKED_LOCATION_REJECTED` (production accounts, I7).
  Future<CheckInResult> checkIn({
    required String spotId,
    required SessionLocation location,
  });

  Future<List<BoardRow>> board(String spotId, BoardTab tab);
}

/// `GET /me`, `GET /movements`.
abstract interface class ProgressionRepository {
  Future<UserProfile> me();

  /// `POST /me` — renames the athlete and returns the updated profile. Throws
  /// `INVALID_HANDLE` or `HANDLE_TAKEN`.
  Future<UserProfile> rename(String handle);

  Future<List<Movement>> movements();
}

/// `GET /challenges/daily`, `POST /challenges/daily/claim`.
abstract interface class ChallengesRepository {
  Future<DailyChallenge> daily();

  /// Throws `NOT_COMPLETE` or `ALREADY_CLAIMED`. Missions may award capped XP
  /// only — territory power accrues only from verified RepScore.
  Future<ChallengeClaim> claimDaily();
}

/// `POST /presence`, `POST /presence/off` — opt-in visibility to nearby
/// athletes. The server keeps only the hex a heartbeat fell in, never the fix.
abstract interface class PresenceRepository {
  /// Marks you visible in the hex containing [location] for the next couple of
  /// minutes and returns the other visible athletes around it. Visibility is
  /// reciprocal: only a visible athlete is shown anyone. Throws
  /// `GPS_TOO_INACCURATE` or `MOCKED_LOCATION_REJECTED`.
  Future<List<NearbyPlayer>> heartbeat(SessionLocation location);

  /// Removes you from everyone's map at once, rather than at the next expiry.
  Future<void> goInvisible();
}

/// `GET /duels`, `POST /duels`, `POST /duels/:id/accept|decline|claim`.
/// One set each, most verified reps wins; the reward is capped XP, never
/// territory power.
abstract interface class DuelsRepository {
  /// Your incoming, open and recently finished duels, newest first.
  Future<List<Duel>> list();

  /// Throws `NOT_VISIBLE`, `NOT_NEARBY` or `DUEL_ALREADY_OPEN`.
  Future<Duel> challenge({
    required String opponentId,
    required String movementId,
  });

  /// Answers an incoming challenge. Throws `UNKNOWN_DUEL` or `DUEL_CLOSED`.
  Future<Duel> respond(String duelId, {required bool accept});

  /// Throws `DUEL_CLOSED` (not finished) or `ALREADY_CLAIMED`.
  Future<ChallengeClaim> claim(String duelId);
}

/// Supabase Auth — not an Edge Function, so it sits beside the endpoint
/// register rather than in it. Every method throws [AccountException] with
/// athlete-facing copy.
abstract interface class AccountRepository {
  Future<AccountState> current();

  /// Attaches [email] and [password] to the current guest account, in place:
  /// same user id, so every score and hex stays put.
  Future<AccountState> saveProgress({
    required String email,
    required String password,
  });

  /// Switches this phone to an existing account. The guest account being left
  /// behind is not merged.
  Future<AccountState> logIn({required String email, required String password});

  /// Signs out and continues as a brand-new guest.
  Future<AccountState> logOut();
}

/// `POST /devices/attest` (Day 6, I5).
abstract interface class DeviceAttestationRepository {
  Future<AttestResult> attest({
    required String platform,
    required String attestationPayload,
  });
}
