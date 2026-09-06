/// Live repositories — the Supabase-backed half of the Seam 2 swap.
///
/// Ownership: B.
///
/// ONLY ROUTES THAT EXIST ARE LIVE. Three of the ~13 endpoints in the register are
/// implemented (`session-start`, `session-submit`, `movements`), so this file
/// implements exactly those and delegates everything else to a stub. That mirrors
/// the server's own `LIVE_ENDPOINTS` mechanism, which puts one route on the live
/// path at a time so a regression is a rollback in seconds rather than a rewrite.
/// Flipping a whole repository to live before its routes exist would trade
/// populated fake data for a 404 — strictly worse for C, who is building screens
/// against it right now.
///
/// Function names are the DEPLOYED directory names under `supabase/functions/`,
/// which is what Kong routes on. The contract writes them with slashes
/// (`POST /session/start`); the wire does not.
library;

import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/models/models.dart';

/// `POST /session/start`, `POST /session/submit`.
class LiveSessionRepository implements SessionRepository {
  const LiveSessionRepository({required this.transport});

  /// Private in effect — nothing outside `api_providers.dart` constructs one of
  /// these — but not in name. Dart forbids a private NAMED parameter, so the
  /// choice is a public field or a positional one; `prefer_initializing_formals`
  /// rules out the `: _transport = transport` middle ground, and naming the
  /// argument at the call site is worth more than the underscore.
  final ApiTransport transport;

  /// Opens a one-shot session (I2). The three fields this returns that the client
  /// could not have chosen — `sessionId`, `movementConfigVersion`, `hexH3` — are
  /// the reason the call exists: submit must echo the first two back and territory
  /// always resolves from the third, so none of them may be minted locally.
  @override
  Future<SessionStart> start({
    required SessionLocation location,
    String? spotId,
  }) async {
    final body = await transport.post('session-start', <String, Object?>{
      'location': location.toJson(),
      'spotId': spotId,
    });
    return SessionStart.fromJson(body);
  }

  /// Consumes the session and returns every consequence in one response (C4).
  ///
  /// The implementation is a pass-through, and that is the invariant rather than an
  /// omission: the client adds NOTHING to [evidence] — no `score`, no `xp`, no
  /// `formFactor` — because the server recomputes all of it (I1). Anything appended
  /// here would be either ignored or, worse, believed.
  @override
  Future<SubmitResult> submit(Map<String, Object?> evidence) async {
    final body = await transport.post('session-submit', evidence);
    return SubmitResult.fromJson(body);
  }
}

/// `GET /movements` is live; `GET /me` has no route yet.
///
/// Split per method rather than per repository so the Profile screen keeps showing
/// realistic data while the exercise picker shows the real seeded catalogue — the
/// same reasoning as the file header, applied one level finer.
class LiveProgressionRepository implements ProgressionRepository {
  const LiveProgressionRepository({
    required this.transport,
    required this.fallback,
  });

  /// Public for the same reason as [LiveSessionRepository.transport].
  final ApiTransport transport;

  /// The stub, used for every method with no deployed route. Passed in rather than
  /// constructed here so the provider decides which stub — and so a test can hand
  /// in one it can assert against.
  final ProgressionRepository fallback;

  @override
  Future<UserProfile> me() => fallback.me();

  /// The catalogue plus this athlete's per-user state. Rows arrive sorted by family
  /// then tier, `difficulty` reaches the wire as a bare number (`1`, not `1.0`) for
  /// every whole-valued multiplier, and `repsTowardNextTier` counts reps banked —
  /// there is no threshold behind it yet, so nothing here may invent a denominator.
  @override
  Future<List<Movement>> movements() async {
    final body = await transport.get('movements');
    return Movement.listFromJson(body);
  }
}
