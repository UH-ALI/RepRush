/// Territory feature providers (feature-scoped — §state rule 1).
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/models/models.dart';

/// The demo venue viewport until real GPS feeds the bbox (D1).
const demoViewport = (
  swLat: DemoVenue.lat - 0.02,
  swLng: DemoVenue.lng - 0.02,
  neLat: DemoVenue.lat + 0.02,
  neLng: DemoVenue.lng + 0.02,
);

/// `GET /territory/hexes?bbox=` — polygons plus owner and power.
final hexesProvider = FutureProvider<List<HexCell>>((ref) {
  return ref
      .watch(territoryRepositoryProvider)
      .hexes(
        swLat: demoViewport.swLat,
        swLng: demoViewport.swLng,
        neLat: demoViewport.neLat,
        neLng: demoViewport.neLng,
      );
});

/// `GET /territory/hex/:h3` — owner, power, your power, spots, recent flips.
final hexDetailProvider = FutureProvider.family<HexDetail, String>((ref, h3) {
  return ref.watch(territoryRepositoryProvider).hexDetail(h3);
});

/// `GET /territory/leaderboard` — hexes held, total area.
final leaderboardProvider = FutureProvider<List<LeaderboardRow>>((ref) {
  return ref.watch(territoryRepositoryProvider).leaderboard();
});
