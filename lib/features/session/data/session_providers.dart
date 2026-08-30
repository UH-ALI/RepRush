/// Session feature providers (feature-scoped — §state rule 1).
///
/// `CaptureController` (§state rule 3) is the sole writer of rep events; it
/// lands with Track A. This file holds only the session lifecycle that B and
/// C need today: start a one-shot session, submit Evidence.
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/models/models.dart';

/// The active one-shot session (I2), or `null` when no session is open.
/// Session context is deterministic: territory always resolves from the
/// server-recorded start context (api-contract.md §session lifecycle).
class ActiveSessionController extends Notifier<SessionStart?> {
  @override
  SessionStart? build() => null;

  /// `POST /session/start` — opens a session against the demo venue until
  /// real location lands (C1).
  Future<SessionStart> start({String? spotId}) async {
    const venue = SessionLocation(lat: 51.5074, lng: -0.1278, accuracyM: 12);
    final started = await ref
        .read(sessionRepositoryProvider)
        .start(location: venue, spotId: spotId);
    state = started;
    return started;
  }

  /// `POST /session/submit` — consumes the session; returns all consequences
  /// in one response (C4). Throws `SESSION_CONTEXT_MISMATCH` etc. per the
  /// contract; the server always uses the session-start context for
  /// territory.
  Future<SubmitResult> submit(Map<String, Object?> evidence) async {
    final result = await ref.read(sessionRepositoryProvider).submit(evidence);
    state = null; // one-shot: submitting consumes the session (I2).
    return result;
  }
}

final activeSessionProvider =
    NotifierProvider<ActiveSessionController, SessionStart?>(
      ActiveSessionController.new,
    );
