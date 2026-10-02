/// Territory feature providers (feature-scoped — §state rule 1).
///
/// ONE LOCATION, EVERYWHERE. The map's marker, the current-hex highlight, the
/// hex sheet's "Train here" gate and session start all read position from the
/// providers below, so the UI can never show you standing in one hex while a
/// session starts from another. Both modes follow the device; the demo falls
/// back to the demo venue when the phone has no fix to give.
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/core/location/location.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/models/models.dart';

const _viewportRadiusDegrees = 0.02;

/// The least power a set must earn to count for territory, and what claims an
/// open hex — the server's `REPRUSH_MIN_CLAIM_POWER`.
const claimFloorPower = 10.0;

/// A good set's form factor (the range is 0.6–1.0), for estimating how many
/// reps a capture needs. Only ever an estimate: the server scores the set.
const typicalFormFactor = 0.9;

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

/// Where the demo world is played: your fix when the phone gives one, the
/// demo venue when it won't (location off, permission refused, no plugin in
/// tests). Never throws — the demo must always open.
Future<SessionLocation> demoLocation() async =>
    await tryReadDeviceLocation() ?? demoVenueLocation;

/// The demo's position feed: the device's while it works, the venue if it
/// never starts.
Stream<SessionLocation> _demoLocationFeed() async* {
  if (!deviceLocationAvailable) {
    yield demoVenueLocation;
    return;
  }
  var any = false;
  try {
    await for (final fix in watchDeviceLocation()) {
      any = true;
      yield fix;
    }
  } catch (_) {
    if (!any) yield demoVenueLocation;
  }
}

/// The anchor the hex grid is fetched around: one fix, refreshed only when the
/// map invalidates it after a long move (see [reanchorDistanceM]). A weak fix
/// is accepted — an approximate map beats no map.
final territoryLocationProvider = FutureProvider<SessionLocation>((ref) {
  if (!ref.watch(isLiveProvider)) return demoLocation();
  return readDeviceLocation(requireAccuracy: false);
});

/// The live position feed behind the "you are here" marker.
final currentLocationProvider = StreamProvider<SessionLocation>((ref) {
  if (!ref.watch(isLiveProvider)) return _demoLocationFeed();
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

/// `GET /territory/mine` — every hex you hold, anywhere. Waits for the map:
/// it refreshes whenever the map does (after a set, say), and the demo lays
/// its territory out around where the map first opened.
final myHexesProvider = FutureProvider<List<HexCell>>((ref) async {
  await ref.watch(hexesProvider.future);
  return ref.watch(territoryRepositoryProvider).myHexes();
});

/// `GET /territory/hex/:h3` — owner, power, your power, spots, recent flips.
final hexDetailProvider = FutureProvider.family<HexDetail, String>((ref, h3) {
  return ref.watch(territoryRepositoryProvider).hexDetail(h3);
});

/// Who holds the hexes on your map — the nearby board. Counted on the phone
/// from the same cells the map draws, so it always agrees with what you see,
/// in Live and Demo alike.
final nearbyLeaderboardProvider = FutureProvider<List<LeaderboardRow>>((
  ref,
) async {
  final cells = await ref.watch(hexesProvider.future);
  // Your row carries your name, as on the global board; "You" only if the
  // profile cannot be read at all.
  String you;
  try {
    you = (await ref.watch(profileProvider.future)).handle;
  } catch (_) {
    you = 'You';
  }
  final counts = <String, int>{};
  for (final cell in cells) {
    final holder = cell.yours ? you : cell.ownerHandle;
    if (holder == null) continue;
    counts[holder] = (counts[holder] ?? 0) + 1;
  }
  return LeaderboardRow.rankCounts(counts, you: you);
});

/// `GET /territory/leaderboard` — the global board: hexes held, total area.
///
/// Demo credits you with the hexes your map shows as yours, so it waits for
/// the map first — otherwise the board and the OWNED count could disagree.
final leaderboardProvider = FutureProvider<List<LeaderboardRow>>((ref) async {
  if (!ref.watch(isLiveProvider)) await ref.watch(hexesProvider.future);
  return ref.watch(territoryRepositoryProvider).leaderboard();
});
