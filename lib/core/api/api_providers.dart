/// Repository bindings — §state rule 2. Every endpoint lives behind a typed
/// repository, and this is the ONLY place a binding chooses between a stub and
/// the live client.
///
/// LIVE OR DEMO, CHOSEN IN THE APP. The build's `REPRUSH_API` is only the
/// default; [appModeProvider] is what the bindings follow, and the Profile
/// screen switches it. Demo binds every repository to its stub — a scripted
/// world around the demo venue that needs no server and no other players.
/// Live binds them to Supabase, which is only offered when the build carries a
/// key ([BackendConfig.canGoLive]). Switching rebuilds every repository, and
/// with them every screen's data.
///
/// Ownership: B.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/core/api/live/live_repositories.dart';
import 'package:reprush/core/api/live/supabase_account.dart';
import 'package:reprush/core/api/live/supabase_transport.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Read once per process. Every value is a `const` dart-define, so a rebuild is
/// the only way to change them — see `backend_config.dart` for why that is the
/// point rather than a limitation.
final backendConfigProvider = Provider<BackendConfig>(
  (ref) => BackendConfig.fromEnvironment(),
);

/// The mode saved on this phone, read by `main.dart` before the first frame so
/// the app opens straight into it. Null (tests, first launch) means the build's
/// default.
final savedApiModeProvider = Provider<ApiMode?>((ref) => null);

/// Live or demo — the switch every binding below follows.
class AppModeController extends Notifier<ApiMode> {
  static const prefsKey = 'app.mode.v1';

  @override
  ApiMode build() {
    final config = ref.watch(backendConfigProvider);
    final wanted = ref.watch(savedApiModeProvider) ?? config.mode;
    // A saved Live choice from a build that had a key, opened in one that has
    // none, falls back to the demo rather than failing every request.
    return wanted == ApiMode.live && !config.canGoLive ? ApiMode.stub : wanted;
  }

  Future<void> select(ApiMode mode) async {
    if (mode == state) return;
    if (mode == ApiMode.live && !ref.read(backendConfigProvider).canGoLive) {
      return;
    }
    if (state == ApiMode.live) {
      // Leaving live: drop off other athletes' maps now rather than lingering
      // until the presence TTL runs out.
      try {
        await ref.read(presenceRepositoryProvider).goInvisible();
      } catch (error) {
        if (kDebugMode) debugPrint('[RepRush] goInvisible on switch: $error');
      }
    }
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, mode.name);
    } catch (_) {
      // Unsaved only means the next launch opens in the build default.
    }
  }
}

final appModeProvider = NotifierProvider<AppModeController, ApiMode>(
  AppModeController.new,
);

/// True in live mode. Location and spots read this rather than the build flag,
/// so the demo pins the athlete to the demo venue whatever the build.
final isLiveProvider = Provider<bool>(
  (ref) => ref.watch(appModeProvider) == ApiMode.live,
);

/// One transport per process: `Supabase.initialize` may run only once, so
/// switching demo → live → demo → live must reuse the same instance.
final _supabaseTransportProvider = Provider<SupabaseTransport>(
  (ref) => SupabaseTransport(ref.watch(backendConfigProvider)),
);

/// Nullable, and the null IS the switch: null in demo mode, so nothing reaches
/// for a server — not even `Supabase.initialize` — until Live is chosen.
final apiTransportProvider = Provider<ApiTransport?>((ref) {
  return ref.watch(isLiveProvider)
      ? ref.watch(_supabaseTransportProvider)
      : null;
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

/// Live: the `presence` function (heartbeat + nearby, hex-level only). Demo:
/// three scripted athletes a hex or two from you.
final presenceRepositoryProvider = Provider<PresenceRepository>((ref) {
  final transport = ref.watch(apiTransportProvider);
  return transport == null
      ? StubPresenceRepository()
      : LivePresenceRepository(transport: transport);
});

/// Live: the `duels` function, scored from real set records. Demo: a scripted
/// opponent that scores your actual set from [StubLedger].
final duelsRepositoryProvider = Provider<DuelsRepository>((ref) {
  final transport = ref.watch(apiTransportProvider);
  return transport == null
      ? StubDuelsRepository()
      : LiveDuelsRepository(transport: transport);
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
