import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// Eigenes, von geolocator entkoppeltes Positionsmodell.
/// Der spaetere Simulator liefert denselben Typ, die NavigationEngine
/// merkt keinen Unterschied zwischen echtem GPS und Simulation.
class GpsFix {
  const GpsFix({
    required this.lat,
    required this.lng,
    required this.speedMps,
    required this.heading,
    required this.accuracy,
    required this.timestamp,
  });

  final double lat;
  final double lng;

  /// Geschwindigkeit in m/s (nie negativ).
  final double speedMps;

  /// Fahrtrichtung in Grad (0 = Nord), -1 wenn unbekannt.
  final double heading;

  /// Horizontale Genauigkeit in Metern.
  final double accuracy;
  final DateTime timestamp;

  LatLng get latLng => LatLng(lat, lng);
  double get speedKmh => speedMps * 3.6;
  bool get hasHeading => heading >= 0;

  factory GpsFix.fromPosition(Position p) => GpsFix(
        lat: p.latitude,
        lng: p.longitude,
        speedMps: p.speed < 0 ? 0 : p.speed,
        heading: p.heading,
        accuracy: p.accuracy,
        timestamp: p.timestamp,
      );
}
