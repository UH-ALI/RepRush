/// Duel providers (feature-scoped — §state rule 1).
///
/// One set each, same exercise, most verified reps wins. Scores are derived
/// server-side from scored sets on every read, so this layer only polls and
/// forwards the athlete's choices. The reward is capped XP claimed explicitly,
/// like the daily challenge (G3) — never territory power (structural rule 4).
///
/// Ownership: B (data).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/features/presence/data/presence_providers.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/models/models.dart';

/// Poll fast while a challenge awaits an answer, steadily while a duel runs,
/// and slowly while you are visible (someone may challenge you). Hidden with
/// nothing open, there is nothing to wait for, so no timer runs at all.
Duration? duelPollInterval(List<Duel> duels, {required bool visible}) {
  if (duels.any((d) => d.status == DuelStatus.pending)) {
    return const Duration(seconds: 3);
  }
  if (duels.any((d) => d.status == DuelStatus.active)) {
    return const Duration(seconds: 8);
  }
  return visible ? const Duration(seconds: 12) : null;
}

class DuelsController extends AsyncNotifier<List<Duel>> {
  @override
  Future<List<Duel>> build() async {
    Timer? poll;
    ref.onDispose(() => poll?.cancel());
    final visible = ref.watch(presenceVisibleProvider).value ?? false;
    try {
      final duels = await ref.watch(duelsRepositoryProvider).list();
      final interval = duelPollInterval(duels, visible: visible);
      if (interval != null) poll = Timer(interval, ref.invalidateSelf);
      return duels;
    } catch (_) {
      // Keep trying while it matters; the error still reaches the UI.
      if (visible) {
        poll = Timer(const Duration(seconds: 12), ref.invalidateSelf);
      }
      rethrow;
    }
  }

  /// Throws `NOT_VISIBLE`, `NOT_NEARBY` or `DUEL_ALREADY_OPEN`.
  Future<Duel> challenge({
    required String opponentId,
    required String movementId,
  }) async {
    final duel = await ref
        .read(duelsRepositoryProvider)
        .challenge(opponentId: opponentId, movementId: movementId);
    ref.invalidateSelf();
    return duel;
  }

  Future<Duel> respond(String duelId, {required bool accept}) async {
    final duel = await ref
        .read(duelsRepositoryProvider)
        .respond(duelId, accept: accept);
    ref.invalidateSelf();
    return duel;
  }

  /// Claims the XP; the profile is refreshed because the level may change.
  Future<ChallengeClaim> claim(String duelId) async {
    final claim = await ref.read(duelsRepositoryProvider).claim(duelId);
    ref
      ..invalidateSelf()
      ..invalidate(profileProvider);
    return claim;
  }
}

final duelsProvider = AsyncNotifierProvider<DuelsController, List<Duel>>(
  DuelsController.new,
);
