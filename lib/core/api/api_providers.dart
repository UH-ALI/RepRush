/// Repository bindings — §state rule 2. Every endpoint lives behind a typed
/// repository, and this is the ONLY place a binding chooses between a stub and
/// the live client. The choice is a build flag (`--dart-define=REPRUSH_API=live`),
/// not an edit, so no widget changes either way.
///
/// Ownership: B.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/live/live_repositories.dart';
import 'package:reprush/core/api/live/supabase_transport.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';

/// Read once per process. Every value is a `const` dart-define, so a rebuild is
/// the only way to change them — see `backend_config.dart` for why that is the
/// point rather than a limitation.
final backendConfigProvider = Provider<BackendConfig>(
  (ref) => BackendConfig.fromEnvironment(),
);

/// Nullable, and the null IS the switch.
///
/// Building a [SupabaseTransport] unconditionally would be harmless at
/// construction, but it calls `Supabase.initialize` against a URL nobody intends
/// to reach the first time any repository is used. That failure would arrive as an
/// app-level transport error with no mention of the build flag that caused it.
final apiTransportProvider = Provider<ApiTransport?>((ref) {
  final config = ref.watch(backendConfigProvider);
  return config.isLive ? SupabaseTransport(config) : null;
});

/// Live: both its routes are deployed (`session-start`, `session-submit`) and
/// verified end to end against the local stack.
final sessionRepositoryProvider = Provider<SessionRepository>((ref) {
  final transport = ref.watch(apiTransportProvider);
  return transport == null
      ? const StubSessionRepository()
      : LiveSessionRepository(transport: transport);
});

/// Split PER METHOD, not per repository: `GET /movements` is deployed, `GET /me`
/// is not. `LiveProgressionRepository` delegates `me()` to the stub handed to it,
/// so the Profile screen keeps showing realistic data while the exercise picker
/// shows the real seeded catalogue.
final progressionRepositoryProvider = Provider<ProgressionRepository>((ref) {
  const fallback = StubProgressionRepository();
  final transport = ref.watch(apiTransportProvider);
  return transport == null
      ? fallback
      : LiveProgressionRepository(transport: transport, fallback: fallback);
});

// ---------------------------------------------------------------------------
// Still stubs — no route is deployed for any of these.
//
// The register lists four more endpoints, but flipping a binding before its
// function exists trades populated fake data for a 404 on screen, which is
// strictly worse for C building against it now. Each moves above when its
// directory lands under `supabase/functions/`.
// ---------------------------------------------------------------------------

final territoryRepositoryProvider = Provider<TerritoryRepository>(
  (ref) => const StubTerritoryRepository(),
);

final spotsRepositoryProvider = Provider<SpotsRepository>(
  (ref) => const StubSpotsRepository(),
);

final challengesRepositoryProvider = Provider<ChallengesRepository>(
  (ref) => StubChallengesRepository(),
);

final deviceAttestationRepositoryProvider =
    Provider<DeviceAttestationRepository>(
      (ref) => const StubDeviceAttestationRepository(),
    );
