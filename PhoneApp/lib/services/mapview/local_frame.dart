import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Lokales ebenes Koordinatensystem um einen Ursprung (Meter).
/// x = Osten, y = Norden. Fuer Ausschnitte von wenigen Kilometern genau genug.
class LocalFrame {
  LocalFrame(this.origin)
      : _kx = metersPerDegree * math.cos(origin.latitude * math.pi / 180);

  /// Meter pro Breitengrad (Erdradius 6371008.8 m, wie in der NavigationEngine).
  static const metersPerDegree = 111194.9266;

  final LatLng origin;
  final double _kx;

  double x(LatLng p) => (p.longitude - origin.longitude) * _kx;
  double y(LatLng p) => (p.latitude - origin.latitude) * metersPerDegree;

  /// Umkehrung von [x]/[y].
  LatLng latLngAt(double x, double y) => LatLng(
        origin.latitude + y / metersPerDegree,
        origin.longitude + x / _kx,
      );
}
