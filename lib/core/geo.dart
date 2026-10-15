import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

const earthRadiusM = 6371008.8;

double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// Grosskreis-Distanz in Metern.
double haversineM(LatLng a, LatLng b) {
  final dLat = _rad(b.latitude - a.latitude);
  final dLon = _rad(b.longitude - a.longitude);
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLon / 2);
  final h = s1 * s1 +
      math.cos(_rad(a.latitude)) * math.cos(_rad(b.latitude)) * s2 * s2;
  return 2 * earthRadiusM * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Anfangskurs von [a] nach [b] in Grad (0 = Nord, 90 = Ost).
double bearingDeg(LatLng a, LatLng b) {
  final p1 = _rad(a.latitude);
  final p2 = _rad(b.latitude);
  final dl = _rad(b.longitude - a.longitude);
  final y = math.sin(dl) * math.cos(p2);
  final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (_deg(math.atan2(y, x)) + 360) % 360;
}

/// Punkt in [distM] Metern Entfernung in Richtung [bearing] (Grad).
/// Naeherung fuer kurze Distanzen (bis einige hundert Meter).
LatLng offsetPoint(LatLng from, double bearing, double distM) {
  final b = _rad(bearing);
  final dLat = distM * math.cos(b) / earthRadiusM;
  final dLon = distM * math.sin(b) / (earthRadiusM * math.cos(_rad(from.latitude)));
  return LatLng(from.latitude + _deg(dLat), from.longitude + _deg(dLon));
}
