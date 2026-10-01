/// Repository bindings — §state rule 2. Every endpoint lives behind a typed
/// repository, and this is the ONLY place a binding chooses between a stub and
/// the live client. Stub mode remains available explicitly with
/// `--dart-define=REPRUSH_API=stub`.
///
/// Ownership: B.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/live/live_repositories.dart';
import 'package:reprush/core/api/live/supabase_account.dart';
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

/// Live whole: `GET /me` and `GET /movements` are both deployed.
final progressionRepositoryProvider = Provider<ProgressionRepository>((ref) {
  final transport = ref.watch(apiTransportProvider);
  return transport == null
      ? const StubProgressionRepository()
      : LiveProgressionRepository(transport: transport);
});

/// Supabase Auth in live builds (guest → email account, log in, log out); an
/// in-memory stand-in in stub builds.
final accountRepositoryProvider = Provider<AccountRepository>((ref) {
  final transport = ref.watch(apiTransportProvider);
  return transport is SupabaseTransport
      ? SupabaseAccountRepository(transport: transport)
      : StubAccountRepository();
});

/// Live whole: both challenge routes ship in the one `challenges` function.
final challengesRepositoryProvider = Provider<ChallengesRepository>((ref) {
  final transport = ref.watch(apiTransportProvider);
  return transport == null
      ? StubChallengesRepository()
      : LiveChallengesRepository(transport: transport);
});

/// Live whole, not per method: all three `territory` routes ship together in one
/// deployed function (map grid, hex detail, leaderboard). Unlike progression there
/// is no half-deployed method to delegate, so no fallback is threaded in — when the
/// transport is null (stub build) the whole repository is the stub, else the whole
/// thing is live. Swapping this is the ONLY change C's map needs on the Day-3 cut:
/// `HexCell`/`HexDetail` keep their shapes and `ownerColor` stays the
/// 'mine'/'rival'/'unclaimed' token vocabulary `map_screen.dart` already renders.
final territoryRepositoryProvider = Provider<TerritoryRepository>((ref) {
  final transport = ref.watch(apiTransportProvider);
  return transport == null
      ? const StubTerritoryRepository()
      : LiveTerritoryRepository(transport: transport);
});

// ---------------------------------------------------------------------------
// Still stubs — no route is deployed for any of these.
//
// The register lists more endpoints, but flipping a binding before its function
// exists trades populated fake data for a 404 on screen, which is strictly worse
// for C building against it now. Each moves above when its directory lands under
// `supabase/functions/`.
// ---------------------------------------------------------------------------

final spotsRepositoryProvider = Provider<SpotsRepository>(
  (ref) => const StubSpotsRepository(),
);

final deviceAttestationRepositoryProvider =
    Provider<DeviceAttestationRepository>(
      (ref) => const StubDeviceAttestationRepository(),
    );
