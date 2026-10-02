/// Territory feature providers (feature-scoped — §state rule 1).
///
/// ONE LOCATION, EVERYWHERE. The map's marker, the current-hex highlight, the
/// hex sheet's "Train here" gate and session start all read position from the
/// providers below, so the UI can never show you standing in one hex while a
/// session starts from another. Stub mode pins all of them to the demo venue;
/// live mode follows the device.
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/core/location/location.dart';
import 'package:reprush/models/models.dart';

const _viewportRadiusDegrees = 0.02;

/// Once the athlete is this far from where the grid was fetched, the map
/// re-fetches around them — about half the viewport's shorter side, so the hex
/// they are standing in is always inside the loaded grid.
const reanchorDistanceM = 1000.0;

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

const demoVenueLocation = SessionLocation(
  lat: DemoVenue.lat,
  lng: DemoVenue.lng,
  accuracyM: 0,
);

/// The anchor the hex grid is fetched around: one fix, refreshed only when the
/// map invalidates it after a long move (see [reanchorDistanceM]). A weak fix
/// is accepted — an approximate map beats no map.
final territoryLocationProvider = FutureProvider<SessionLocation>((ref) {
  if (!ref.watch(isLiveProvider)) return Future.value(demoVenueLocation);
  return readDeviceLocation(requireAccuracy: false);
});

/// The live position feed behind the "you are here" marker.
final currentLocationProvider = StreamProvider<SessionLocation>((ref) {
  if (!ref.watch(isLiveProvider)) {
    return Stream.value(demoVenueLocation);
  }
  return watchDeviceLocation();
});

/// Best-known position right now: the live feed, else the anchor fix.
final hereProvider = Provider<SessionLocation?>((ref) {
  return ref.watch(currentLocationProvider).value ??
      ref.watch(territoryLocationProvider).value;
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

/// The hex the athlete is standing in, resolved against the polygons the
/// server sent. Null while either input is loading, or when the fix is outside
/// the loaded grid (the map re-anchors before that lasts).
final currentHexProvider = Provider<HexCell?>((ref) {
  final cells = ref.watch(hexesProvider).value;
  final here = ref.watch(hereProvider);
  if (cells == null || here == null) return null;
  return hexContaining(cells, here.lat, here.lng);
});

/// `GET /territory/hex/:h3` — owner, power, your power, spots, recent flips.
final hexDetailProvider = FutureProvider.family<HexDetail, String>((ref, h3) {
  return ref.watch(territoryRepositoryProvider).hexDetail(h3);
});

/// `GET /territory/leaderboard` — hexes held, total area.
final leaderboardProvider = FutureProvider<List<LeaderboardRow>>((ref) {
  return ref.watch(territoryRepositoryProvider).leaderboard();
});
