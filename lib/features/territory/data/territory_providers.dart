/// Territory feature providers (feature-scoped — §state rule 1).
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/core/location/location.dart';
import 'package:reprush/models/models.dart';

const _viewportRadiusDegrees = 0.02;

typedef TerritoryViewport = ({
  double swLat,
  double swLng,
  double neLat,
  double neLng,
});

TerritoryViewport viewportAround(double lat, double lng) => (
  swLat: lat - _viewportRadiusDegrees,
  swLng: lng - _viewportRadiusDegrees,
  neLat: lat + _viewportRadiusDegrees,
  neLng: lng + _viewportRadiusDegrees,
);

final territoryLocationProvider = FutureProvider<SessionLocation>((ref) {
  final config = ref.watch(backendConfigProvider);
  if (!config.isLive) {
    return Future.value(
      const SessionLocation(
        lat: DemoVenue.lat,
        lng: DemoVenue.lng,
        accuracyM: 0,
      ),
    );
  }
  return readDeviceLocation();
});

/// `GET /territory/hexes?bbox=` — polygons plus owner and power.
final hexesProvider = FutureProvider<List<HexCell>>((ref) async {
  final location = await ref.watch(territoryLocationProvider.future);
  final viewport = viewportAround(location.lat, location.lng);
  return ref
      .watch(territoryRepositoryProvider)
      .hexes(
        swLat: viewport.swLat,
        swLng: viewport.swLng,
        neLat: viewport.neLat,
        neLng: viewport.neLng,
      );
});

/// `GET /spots/nearby` around the demo/player location.
final nearbySpotsProvider = FutureProvider<List<SpotSummary>>((ref) async {
  if (ref.watch(backendConfigProvider).isLive) {
    // The current Supabase schema has no spots route/table. Do not show
    // fabricated demo spots alongside live territory.
    return Future.value(const <SpotSummary>[]);
  }
  final location = await ref.watch(territoryLocationProvider.future);
  return ref
      .watch(spotsRepositoryProvider)
      .nearby(lat: location.lat, lng: location.lng);
});

/// `GET /territory/hex/:h3` — owner, power, your power, spots, recent flips.
final hexDetailProvider = FutureProvider.family<HexDetail, String>((ref, h3) {
  return ref.watch(territoryRepositoryProvider).hexDetail(h3);
});

/// `GET /territory/leaderboard` — hexes held, total area.
final leaderboardProvider = FutureProvider<List<LeaderboardRow>>((ref) {
  return ref.watch(territoryRepositoryProvider).leaderboard();
});
