import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../../core/models/nav_route.dart';
import 'routing_service.dart';

/// OpenRouteService Directions, Profil driving-car.
class OrsRoutingService implements RoutingService {
  OrsRoutingService(this._client, this._apiKey);

  final http.Client _client;
  final String _apiKey;

  static final _uri =
      Uri.https('api.openrouteservice.org', '/v2/directions/driving-car/geojson');

  @override
  Future<NavRoute> route({required LatLng from, required LatLng to}) async {
    final body = jsonEncode({
      // ORS erwartet [lon, lat]
      'coordinates': [
        [from.longitude, from.latitude],
        [to.longitude, to.latitude],
      ],
      'language': 'de',
      'instructions': true,
      'units': 'm',
    });

    final http.Response res;
    try {
      res = await _client
          .post(
            _uri,
            headers: {
              'Authorization': _apiKey,
              'Content-Type': 'application/json; charset=utf-8',
              'Accept': 'application/geo+json',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const RoutingException('Zeitüberschreitung bei der Routenberechnung.');
    } on SocketException {
      throw const RoutingException('Keine Internetverbindung.');
    } on http.ClientException {
      throw const RoutingException('Keine Internetverbindung.');
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const RoutingException('ORS-API-Key ungültig oder nicht freigegeben.');
    }
    if (res.statusCode == 429) {
      throw const RoutingException('ORS-Anfragelimit erreicht. Kurz warten.');
    }
    if (res.statusCode != 200) {
      throw RoutingException(_errorMessage(res));
    }

    try {
      return _parse(jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      throw const RoutingException('Unerwartete Antwort vom Routing-Server.');
    }
  }

  String _errorMessage(http.Response res) {
    try {
      final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final code = (json['error'] as Map<String, dynamic>?)?['code'];
      if (code == 2010) {
        return 'Start oder Ziel liegt zu weit von einer befahrbaren Straße entfernt.';
      }
      if (code == 2009) return 'Keine Route zwischen Start und Ziel gefunden.';
    } catch (_) {}
    return 'Routenberechnung fehlgeschlagen (${res.statusCode}).';
  }

  NavRoute _parse(Map<String, dynamic> json) {
    final feature = (json['features'] as List).first as Map<String, dynamic>;
    final coords = (feature['geometry'] as Map<String, dynamic>)['coordinates'] as List;
    final points = [
      for (final c in coords)
        LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
    ];

    final props = feature['properties'] as Map<String, dynamic>;
    final summary = props['summary'] as Map<String, dynamic>;

    final steps = <RouteStep>[];
    for (final seg in (props['segments'] as List)) {
      for (final s in ((seg as Map<String, dynamic>)['steps'] as List)) {
        final m = s as Map<String, dynamic>;
        final wp = (m['way_points'] as List).map((e) => (e as num).toInt()).toList();
        final name = (m['name'] as String?) ?? '';
        steps.add(RouteStep(
          type: TurnType.fromOrs((m['type'] as num).toInt()),
          instruction: (m['instruction'] as String?) ?? '',
          streetName: name == '-' ? '' : name,
          distanceM: (m['distance'] as num).toDouble(),
          durationS: (m['duration'] as num).toDouble(),
          startIndex: wp[0],
          endIndex: wp[1],
          exitNumber: (m['exit_number'] as num?)?.toInt(),
        ));
      }
    }

    return NavRoute(
      points: points,
      steps: steps,
      distanceM: (summary['distance'] as num).toDouble(),
      durationS: (summary['duration'] as num).toDouble(),
    );
  }
}
