/// Plain-coordinate geometry for the client: which polygon a fix falls in, and
/// how far away a hex is.
///
/// Pure Dart, no plugins. The client never computes H3 (requirements.md §8
/// open-1) — the server sends each hex as a coordinate polygon, and the only
/// question the client asks of it is "is this point inside?", which needs no H3
/// library. The server stays authoritative: territory always resolves from the
/// hex it records at session start. This is what lets the UI refuse to promise a
/// capture the server would never grant.
library;

import 'dart:math' as math;

import 'package:reprush/models/models.dart';

const double _earthRadiusM = 6371008.8;

/// Ray-casting point-in-polygon on raw lat/lng. Planar maths is fine at hex
/// scale (~0.5 km across), well inside where curvature matters.
bool polygonContains(List<GeoPoint> polygon, double lat, double lng) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final a = polygon[i];
    final b = polygon[j];
    final crosses = (a.lng > lng) != (b.lng > lng);
    if (crosses &&
        lat < (b.lat - a.lat) * (lng - a.lng) / (b.lng - a.lng) + a.lat) {
      inside = !inside;
    }
  }
  return inside;
}

/// The cell containing the fix, or null when it lies outside every cell loaded.
HexCell? hexContaining(Iterable<HexCell> cells, double lat, double lng) {
  for (final cell in cells) {
    if (polygonContains(cell.polygon, lat, lng)) return cell;
  }
  return null;
}

/// The vertex average — the visual centre for a convex hex, which is all the
/// "how far is it" copy needs.
GeoPoint polygonCentre(List<GeoPoint> polygon) {
  var lat = 0.0;
  var lng = 0.0;
  for (final p in polygon) {
    lat += p.lat;
    lng += p.lng;
  }
  return GeoPoint(lat: lat / polygon.length, lng: lng / polygon.length);
}

/// Great-circle distance in metres (the same haversine the server uses).
double distanceM(double aLat, double aLng, double bLat, double bLng) {
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(bLat - aLat);
  final dLng = rad(bLng - aLng);
  final s =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(aLat)) * math.cos(rad(bLat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * _earthRadiusM * math.asin(math.min(1, math.sqrt(s)));
}

/// "350 m" / "1.2 km" — distance copy for athlete-facing text.
String formatDistance(double metres) {
  if (metres < 1000) return '${(metres / 10).round() * 10} m';
  return '${(metres / 1000).toStringAsFixed(1)} km';
}
