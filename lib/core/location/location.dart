/// Device location access shared by session and territory features.
///
/// Two ways in, because the map and a session need different guarantees:
///
///   - [watchDeviceLocation] is the continuous feed behind the map's "you are
///     here" marker and the current-hex highlight. It never rejects a weak fix —
///     a 70 m fix still shows roughly where you are, and refusing to draw the map
///     indoors would be worse than drawing it approximately.
///   - [readDeviceLocation] with `requireAccuracy` is the one-shot fix a session
///     starts from. It mirrors the server's D4 gate (50 m) so the athlete gets a
///     plain-language reason before a round trip, not a `GPS_TOO_INACCURATE` code
///     after one. The server still enforces the gate; this is only the early,
///     friendlier copy of it.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:geolocator/geolocator.dart';
import 'package:reprush/models/models.dart';

/// The server's D4 gate (`MAX_GPS_ACCURACY_M` in `_shared/validation/geo.ts`).
const double maxSessionAccuracyM = 50;

const _streamSettings = LocationSettings(
  accuracy: LocationAccuracy.high,
  // Metres between updates. Small enough that crossing a hex edge (~460 m
  // across at res 8) is noticed promptly, large enough not to churn rebuilds.
  distanceFilter: 5,
);

/// The check currently in flight, shared by every caller.
///
/// On first launch the map's anchor fix and its live feed both ask for access
/// in the same frame. Android allows ONE runtime-permission request at a time
/// ("Can request only one set of permissions at a time"): the second request
/// is cancelled with an empty result, which surfaced as the map spinning
/// forever. Callers now join the same request instead of racing it.
Future<void>? _accessCheck;

/// Throws [LocationException] when location is off or permission is refused.
Future<void> ensureLocationAccess() {
  final inFlight = _accessCheck;
  if (inFlight != null) return inFlight;
  final check = _checkLocationAccess();
  _accessCheck = check;
  // Forget the result once settled: a user who denied and then enabled
  // location in settings must be re-checked, not served a stale failure.
  void clear() => _accessCheck = null;
  check.then((_) => clear(), onError: (_) => clear());
  return check;
}

Future<void> _checkLocationAccess() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationException(
      'Location is turned off. Turn it on so RepRush can tell which hex '
      "you're standing in.",
    );
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw const LocationException(
      'RepRush needs location access to know which hex you are in. Allow it '
      'in your phone settings to play.',
    );
  }
}

/// One fresh, high-accuracy fix.
///
/// [requireAccuracy] (session start) throws when the fix is worse than
/// [maxSessionAccuracyM]; the map passes `false` and takes whatever it gets.
Future<SessionLocation> readDeviceLocation({
  bool requireAccuracy = true,
}) async {
  await ensureLocationAccess();
  final Position position;
  try {
    position = await Geolocator.getCurrentPosition(
      // Without a limit a cold GPS (indoors) waits forever and the map
      // never leaves its loading state.
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 20),
      ),
    );
  } on TimeoutException {
    throw const LocationException(
      "Couldn't get a GPS fix. Step outside or near a window and try again.",
    );
  }
  final location = _fromPosition(position);
  if (requireAccuracy && location.accuracyM > maxSessionAccuracyM) {
    throw LocationException(
      'Your GPS signal is too weak to claim territory '
      '(±${location.accuracyM.round()} m). Move near a window or step '
      'outside and try again.',
    );
  }
  return location;
}

/// Best effort, never throws: a fresh fix of any accuracy, else the phone's last
/// known one, else null. For the demo world, which should be played where you
/// stand when the phone allows it and must never refuse to open when it won't.
Future<SessionLocation?> tryReadDeviceLocation({
  Duration timeout = const Duration(seconds: 10),
}) async {
  if (!deviceLocationAvailable) return null;
  try {
    return await readDeviceLocation(requireAccuracy: false).timeout(timeout);
  } catch (_) {
    // Fall through to the last known fix.
  }
  try {
    final last = await Geolocator.getLastKnownPosition().timeout(
      const Duration(seconds: 2),
    );
    if (last != null) return _fromPosition(last);
  } catch (_) {
    // No location at all — the caller has a fallback.
  }
  return null;
}

/// False under `flutter test`, where there is no GPS and a plugin call is
/// never answered — the demo's best-effort lookups skip straight to their
/// fallback instead of waiting on it.
final bool deviceLocationAvailable = !Platform.environment.containsKey(
  'FLUTTER_TEST',
);

/// A continuous feed of fixes: the current one first, then every move of at
/// least a few metres.
Stream<SessionLocation> watchDeviceLocation() async* {
  await ensureLocationAccess();
  yield await readDeviceLocation(requireAccuracy: false);
  yield* Geolocator.getPositionStream(
    locationSettings: _streamSettings,
  ).map(_fromPosition);
}

SessionLocation _fromPosition(Position position) => SessionLocation(
  lat: position.latitude,
  lng: position.longitude,
  accuracyM: position.accuracy,
  isMocked: position.isMocked,
);

class LocationException implements Exception {
  const LocationException(this.message);

  final String message;

  @override
  String toString() => message;
}
