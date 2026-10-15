import 'package:latlong2/latlong.dart';

import '../../core/models/nav_route.dart';

class RoutingException implements Exception {
  const RoutingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Schnittstelle zur Routenberechnung. Wird auch fuer die Neuberechnung
/// bei Abweichung genutzt (Schritt 4).
abstract interface class RoutingService {
  Future<NavRoute> route({required LatLng from, required LatLng to});
}
