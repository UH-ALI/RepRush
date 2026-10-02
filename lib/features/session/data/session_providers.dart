/// Session feature providers (feature-scoped — §state rule 1).
///
/// `CaptureController` (§state rule 3) is the sole writer of rep events; it
/// lands with Track A. This file holds the session lifecycle B and C need:
/// start a one-shot session where the athlete is standing, submit Evidence, and
/// refresh every screen that shows the consequences.
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart'
    show StubDuelsRepository, StubLedger, StubWorld;
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/core/location/location.dart';
import 'package:reprush/features/challenges/data/challenges_providers.dart';
import 'package:reprush/features/challenges/data/duels_providers.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';

/// Why a session cannot start where the athlete is. [message] is athlete-facing
/// copy, safe to show as-is.
class TrainingBlocked implements Exception {
  const TrainingBlocked(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The active one-shot session (I2), or `null` when no session is open.
/// Session context is deterministic: territory always resolves from the
/// server-recorded start context (api-contract.md §session lifecycle).
class ActiveSessionController extends Notifier<SessionStart?> {
  @override
  SessionStart? build() {
    // A session belongs to one backend: switching live ↔ demo drops it.
    ref.watch(isLiveProvider);
    _startLocation = null;
    return null;
  }

  /// The exact location used in the most recent [start] call — the same
  /// object the server recorded. Capture needs this for Evidence's
  /// `location` block (§evidence: must match the session-start fix within
  /// CONTEXT_MATCH_RADIUS_M).
  SessionLocation? _startLocation;

  /// Read-only accessor for the retained start location.
  SessionLocation? get startLocation => _startLocation;

  /// The ONE way the UI opens a session — the map's hex sheet and the workout
  /// tab both come through here.
  ///
  /// Takes a fresh, accuracy-gated fix. When [targetH3] names the hex the
  /// athlete tapped, the fix must be inside it: the server credits the hex the
  /// athlete is actually standing in no matter what was tapped (territory
  /// resolves from the server-recorded start fix), so opening a session "for" a
  /// hex across town would only promise a capture that can never happen.
  Future<SessionStart> startHere({String? targetH3}) async {
    final location = await readSessionLocation(ref);
    if (targetH3 != null) {
      final cells = await ref.read(hexesProvider.future);
      final target = cells.where((c) => c.h3 == targetH3).firstOrNull;
      if (target != null &&
          !polygonContains(target.polygon, location.lat, location.lng)) {
        final centre = polygonCentre(target.polygon);
        final away = distanceM(
          location.lat,
          location.lng,
          centre.lat,
          centre.lng,
        );
        throw TrainingBlocked(
          "You're ${formatDistance(away)} from this hex. Walk into it to "
          'train for it.',
        );
      }
    }
    return start(location: location);
  }

  /// `POST /session/start` — opens a session at [location] (C1). Prefer
  /// [startHere]; this is the raw call it wraps.
  Future<SessionStart> start({
    required SessionLocation location,
    String? spotId,
  }) async {
    var started = await ref
        .read(sessionRepositoryProvider)
        .start(location: location, spotId: spotId);
    if (!ref.read(isLiveProvider) && ref.read(hasServerProvider)) {
      started = await _onRealMap(started, location);
    }
    _startLocation = location;
    state = started;
    return started;
  }

  /// A demo set over the real map belongs to the REAL hex you are standing
  /// in, so the capture lands on the cell the map highlights. Whether it was
  /// already yours decides "captured" versus "power added" on the summary.
  Future<SessionStart> _onRealMap(
    SessionStart started,
    SessionLocation location,
  ) async {
    final cells = await ref.read(hexesProvider.future);
    final cell = hexContaining(cells, location.lat, location.lng);
    if (cell == null) return started;
    StubWorld.beginSession(
      cell.h3,
      wasYours: cell.yours,
      holderPower: cell.power,
    );
    return SessionStart(
      sessionId: started.sessionId,
      serverStartMs: started.serverStartMs,
      movementConfigVersion: started.movementConfigVersion,
      hexH3: cell.h3,
      spotId: started.spotId,
      expiresAtMs: started.expiresAtMs,
    );
  }

  /// Drops the local session without submitting. The server row simply expires
  /// (4 h, I2) — nothing is scored, and nothing can be replayed later because
  /// the id is forgotten here.
  void abandon() {
    _startLocation = null;
    state = null;
  }

  /// `POST /session/submit` — consumes the session; returns all consequences
  /// in one response (C4). Throws `SESSION_CONTEXT_MISMATCH` etc. per the
  /// contract; the server always uses the session-start context for
  /// territory.
  ///
  /// On success every provider that shows a consequence is invalidated, so the
  /// map's hex colour, the leaderboard, XP/level and challenge progress all
  /// reflect the set the moment the summary is dismissed.
  Future<SubmitResult> submit(Map<String, Object?> evidence) async {
    final result = await ref.read(sessionRepositoryProvider).submit(evidence);
    state = null; // one-shot: submitting consumes the session (I2).
    _startLocation = null;
    // A stub duel scores the set the server just accepted — the stand-in for
    // the live `duels` route reading set_records.
    if (ref.read(duelsRepositoryProvider) is StubDuelsRepository) {
      StubLedger.recordEvidence(evidence);
    }
    ref
      ..invalidate(duelsProvider)
      ..invalidate(hexDetailProvider)
      ..invalidate(hexesProvider)
      ..invalidate(leaderboardProvider)
      ..invalidate(profileProvider)
      ..invalidate(movementsProvider)
      ..invalidate(dailyChallengeProvider);
    return result;
  }
}

final activeSessionProvider =
    NotifierProvider<ActiveSessionController, SessionStart?>(
      ActiveSessionController.new,
    );

/// The fix a session starts from. Stub mode uses the demo venue — the same
/// place the stub map is drawn around — so the hex gate is consistent there
/// too; live mode takes a fresh device fix that must pass the 50 m gate.
Future<SessionLocation> readSessionLocation(Ref ref) async {
  if (!ref.read(isLiveProvider)) return demoLocation();
  return readDeviceLocation();
}
