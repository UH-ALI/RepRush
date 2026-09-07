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
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/core/location/location.dart';
import 'package:reprush/models/models.dart';

/// The active one-shot session (I2), or `null` when no session is open.
/// Session context is deterministic: territory always resolves from the
/// server-recorded start context (api-contract.md §session lifecycle).
class ActiveSessionController extends Notifier<SessionStart?> {
  @override
  SessionStart? build() {
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

  /// `POST /session/start` — opens a session using the device location (C1).
  Future<SessionStart> start({
    required SessionLocation location,
    String? spotId,
  }) async {
    final started = await ref
        .read(sessionRepositoryProvider)
        .start(location: location, spotId: spotId);
    _startLocation = location;
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
    _startLocation = null;
    return result;
  }
}

final activeSessionProvider =
    NotifierProvider<ActiveSessionController, SessionStart?>(
      ActiveSessionController.new,
    );

Future<SessionLocation> readSessionLocation([BackendConfig? config]) async {
  if (config != null && !config.isLive) {
    return const SessionLocation(
      lat: DemoVenue.lat,
      lng: DemoVenue.lng,
      accuracyM: 0,
    );
  }
  return readDeviceLocation();
}
