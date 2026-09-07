/// Device location access shared by session and territory features.
library;

import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:reprush/models/models.dart';

Future<SessionLocation> readDeviceLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationException(
      'Location services are disabled. Enable GPS to record your session and territory.',
    );
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw const LocationException(
      'Location permission is required to record your workout session and territory.',
    );
  }

  Position? position;
  try {
    position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );
  } on TimeoutException {
    final lastKnown = await Geolocator.getLastKnownPosition();
    if (lastKnown != null && lastKnown.accuracy <= 50) {
      position = lastKnown;
    } else {
      throw const LocationException(
        'GPS fix timed out. Move outdoors or near an open window and try again.',
      );
    }
  }

  if (position.accuracy > 50) {
    throw const LocationException(
      'GPS accuracy is too low (> 50 m). Move outdoors and try again.',
    );
  }
  return SessionLocation(
    lat: position.latitude,
    lng: position.longitude,
    accuracyM: position.accuracy,
    isMocked: position.isMocked,
  );
}

class LocationException implements Exception {
  const LocationException(this.message);

  final String message;

  @override
  String toString() => message;
}
