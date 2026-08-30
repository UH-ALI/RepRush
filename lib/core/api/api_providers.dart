/// Repository bindings — §state rule 2. Every endpoint lives behind a typed
/// repository; today the bindings point at realistic stubs, and B swaps each
/// for a Supabase-backed implementation without touching a single widget.
///
/// Ownership: B.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';

final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => const StubSessionRepository(),
);

final territoryRepositoryProvider = Provider<TerritoryRepository>(
  (ref) => const StubTerritoryRepository(),
);

final spotsRepositoryProvider = Provider<SpotsRepository>(
  (ref) => const StubSpotsRepository(),
);

final progressionRepositoryProvider = Provider<ProgressionRepository>(
  (ref) => const StubProgressionRepository(),
);

final challengesRepositoryProvider = Provider<ChallengesRepository>(
  (ref) => StubChallengesRepository(),
);

final deviceAttestationRepositoryProvider =
    Provider<DeviceAttestationRepository>(
      (ref) => const StubDeviceAttestationRepository(),
    );
