import 'package:latlong2/latlong.dart';

import '../../core/models/place.dart';

class GeocodingException implements Exception {
  const GeocodingException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Schnittstelle fuer die Zielsuche. Implementierungen sind austauschbar.
abstract interface class GeocodingService {
  /// Vorschlaege waehrend des Tippens. Leere Liste, wenn der Anbieter das
  /// nicht erlaubt (Nominatim).
  Future<List<Place>> autocomplete(String text, {LatLng? focus});

  /// Vollsuche (nach Druck auf "Suchen").
  Future<List<Place>> search(String text, {LatLng? focus});
}
