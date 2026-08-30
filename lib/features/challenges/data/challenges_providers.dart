/// Challenges feature providers (feature-scoped — §state rule 1).
///
/// Slice 1 ships one static seeded daily challenge, identical for everyone.
/// Missions may award capped XP only; territory power accrues only from
/// verified RepScore earned in a session (requirements.md structural rule 4).
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/models/models.dart';

/// `GET /challenges/daily` plus the explicit claim step (G3) — claiming
/// feels better than auto-award.
class DailyChallengeController extends AsyncNotifier<DailyChallenge> {
  @override
  Future<DailyChallenge> build() {
    return ref.watch(challengesRepositoryProvider).daily();
  }

  /// `POST /challenges/daily/claim`. Refreshes the challenge state on
  /// success; propagates `NOT_COMPLETE` / `ALREADY_CLAIMED` to the caller.
  Future<ChallengeClaim> claim() async {
    final claim = await ref.read(challengesRepositoryProvider).claimDaily();
    final updated = await ref.read(challengesRepositoryProvider).daily();
    state = AsyncData(updated);
    return claim;
  }
}

final dailyChallengeProvider =
    AsyncNotifierProvider<DailyChallengeController, DailyChallenge>(
      DailyChallengeController.new,
    );
