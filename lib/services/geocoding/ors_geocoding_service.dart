import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/models/place.dart';
import 'geocoding_service.dart';

/// OpenRouteService (Pelias). Unterstuetzt Autocomplete.
class OrsGeocodingService implements GeocodingService {
  OrsGeocodingService(this._client, this._apiKey);

  final http.Client _client;
  final String _apiKey;
  static const _host = 'api.openrouteservice.org';

  @override
  Future<List<Place>> autocomplete(String text, {LatLng? focus}) =>
      _query('/geocode/autocomplete', text, focus);

  @override
  Future<List<Place>> search(String text, {LatLng? focus}) =>
      _query('/geocode/search', text, focus);

  Future<List<Place>> _query(String path, String text, LatLng? focus) async {
    final uri = Uri.https(_host, path, {
      'api_key': _apiKey,
      'text': text,
      'size': '6',
      if (focus != null) 'focus.point.lat': focus.latitude.toString(),
      if (focus != null) 'focus.point.lon': focus.longitude.toString(),
    });

    final http.Response res;
    try {
      res = await _client.get(uri).timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const GeocodingException('Zeitüberschreitung bei der Suche.');
    } on SocketException {
      throw const GeocodingException('Keine Internetverbindung.');
    } on http.ClientException {
      throw const GeocodingException('Keine Internetverbindung.');
    }

    // Fehlermeldungen enthalten bewusst nie die URL (wegen des API-Keys).
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const GeocodingException('ORS-API-Key ungültig oder nicht freigegeben.');
    }
    if (res.statusCode == 429) {
      throw const GeocodingException('ORS-Anfragelimit erreicht. Kurz warten.');
    }
    if (res.statusCode != 200) {
      throw GeocodingException('Geocoding-Fehler (${res.statusCode}).');
    }

    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final features = (json['features'] as List?) ?? const [];
    final places = <Place>[];
    for (final f in features) {
      final feature = f as Map<String, dynamic>;
      final coords = (feature['geometry']?['coordinates'] as List?);
      final props = feature['properties'] as Map<String, dynamic>?;
      if (coords == null || coords.length < 2 || props == null) continue;
      final label = (props['label'] as String?) ?? (props['name'] as String?) ?? '';
      if (label.isEmpty) continue;
      places.add(Place(
        name: (props['name'] as String?) ?? label,
        label: label,
        // GeoJSON: [lon, lat]
        position: LatLng((coords[1] as num).toDouble(), (coords[0] as num).toDouble()),
      ));
    }
    return places;
  }
}
