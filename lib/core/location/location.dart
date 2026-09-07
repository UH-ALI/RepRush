/// Device location access shared by session and territory features.
library;

import 'package:geolocator/geolocator.dart';
import 'package:reprush/models/models.dart';

Future<SessionLocation> readDeviceLocation() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw const LocationException(
      'Location services are disabled. Enable them to view your territory.',
    );
  }

  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    throw const LocationException(
      'Location permission is required to view your territory.',
    );
  }

  final position = await Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
  );
  if (position.accuracy > 50) {
    throw const LocationException(
      'GPS accuracy is too low. Move outdoors and try again.',
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
