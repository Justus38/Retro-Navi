import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/models/place.dart';
import 'geocoding_service.dart';

/// Fallback ohne API-Key. Die Nutzungsrichtlinie von Nominatim verbietet
/// Autocomplete, deshalb gibt es nur die Vollsuche (max. 1 Anfrage/s).
class NominatimGeocodingService implements GeocodingService {
  NominatimGeocodingService(this._client, this._userAgent);

  final http.Client _client;
  final String _userAgent;

  @override
  Future<List<Place>> autocomplete(String text, {LatLng? focus}) async => const [];

  @override
  Future<List<Place>> search(String text, {LatLng? focus}) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': text,
      'format': 'jsonv2',
      'limit': '6',
    });

    final http.Response res;
    try {
      res = await _client
          .get(uri, headers: {'User-Agent': _userAgent})
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      throw const GeocodingException('Zeitüberschreitung bei der Suche.');
    } on SocketException {
      throw const GeocodingException('Keine Internetverbindung.');
    } on http.ClientException {
      throw const GeocodingException('Keine Internetverbindung.');
    }

    if (res.statusCode == 429) {
      throw const GeocodingException('Nominatim-Limit erreicht. Kurz warten.');
    }
    if (res.statusCode != 200) {
      throw GeocodingException('Geocoding-Fehler (${res.statusCode}).');
    }

    final list = jsonDecode(utf8.decode(res.bodyBytes)) as List;
    final places = <Place>[];
    for (final item in list) {
      final m = item as Map<String, dynamic>;
      final label = (m['display_name'] as String?) ?? '';
      final lat = double.tryParse('${m['lat']}');
      final lon = double.tryParse('${m['lon']}');
      if (label.isEmpty || lat == null || lon == null) continue;
      final name = (m['name'] as String?)?.isNotEmpty == true
          ? m['name'] as String
          : label.split(',').first.trim();
      places.add(Place(name: name, label: label, position: LatLng(lat, lon)));
    }
    return places;
  }
}
