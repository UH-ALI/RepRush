/// Presence feature providers (feature-scoped — §state rule 1): whether you
/// have opted in to being seen, and who else is visible around you.
///
/// PRIVACY SHAPE. Off by default, and the choice is remembered on this phone.
/// While on, a heartbeat puts you in your current HEX for a couple of minutes —
/// the server keeps the cell, never the fix (N7) — and returns the other
/// visible athletes nearby. Turning it off removes you at once rather than at
/// the next expiry. Visibility is reciprocal: you only see others while they
/// can see you.
///
/// Ownership: B (data).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How often a visible athlete re-announces their hex and refreshes who is
/// around. Well inside the server's two-minute expiry, so one dropped request
/// never blinks you off anyone's map.
const presencePollInterval = Duration(seconds: 15);

/// The opt-in switch. Persisted so the choice survives a restart, and always
/// `false` until the athlete says otherwise.
class PresenceVisibilityController extends AsyncNotifier<bool> {
  static const prefsKey = 'presence.visible.v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? false;
  }

  Future<void> setVisible(bool visible) async {
    state = AsyncData(visible);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, visible);
    if (!visible) {
      // Best effort: if this fails, the server's expiry hides you anyway.
      try {
        await ref.read(presenceRepositoryProvider).goInvisible();
      } catch (error) {
        if (kDebugMode) debugPrint('[RepRush] goInvisible failed: $error');
      }
    }
  }
}

final presenceVisibleProvider =
    AsyncNotifierProvider<PresenceVisibilityController, bool>(
      PresenceVisibilityController.new,
    );

/// Visible athletes near you — empty while you are hidden. Each tick sends
/// one heartbeat from [hereProvider], which both keeps you visible and
/// answers with who else is.
///
/// A failed heartbeat keeps the last list rather than emptying the map: a
/// weak fix indoors should not make everyone vanish for fifteen seconds.
final nearbyPlayersProvider = StreamProvider<List<NearbyPlayer>>((ref) async* {
  final visible = ref.watch(presenceVisibleProvider).value ?? false;
  if (!visible) {
    yield const [];
    return;
  }
  final repository = ref.watch(presenceRepositoryProvider);
  var players = const <NearbyPlayer>[];
  while (ref.mounted) {
    final here = ref.read(hereProvider);
    if (here == null) {
      // No fix yet — try again shortly rather than a whole interval later.
      await Future<void>.delayed(const Duration(seconds: 2));
      continue;
    }
    try {
      players = await repository.heartbeat(here);
    } catch (error) {
      if (kDebugMode) debugPrint('[RepRush] presence heartbeat: $error');
    }
    if (!ref.mounted) return;
    yield players;
    await Future<void>.delayed(presencePollInterval);
  }
});
