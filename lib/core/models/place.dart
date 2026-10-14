import 'package:latlong2/latlong.dart';

/// Ein Geocoding-Treffer (Ziel oder Vorschlag).
class Place {
  const Place({required this.name, required this.label, required this.position});

  /// Kurzname, z. B. "Marienplatz".
  final String name;

  /// Vollstaendige Beschriftung, z. B. "Marienplatz, Muenchen, Bayern, Deutschland".
  final String label;

  final LatLng position;

  @override
  bool operator ==(Object other) =>
      other is Place && other.label == label && other.position == position;

  @override
  int get hashCode => Object.hash(label, position);
}
