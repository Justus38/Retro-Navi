import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'mvt_decoder.dart';
import 'road_models.dart';

/// Vektorkacheln von OpenFreeMap (kostenlos, ohne Schluessel).
///
/// Die Kachel-Adresse enthaelt eine Versionsnummer, die sich aendert. Deshalb
/// wird sie aus dem TileJSON gelesen (beim ersten Zugriff und danach alle
/// [templateMaxAge]). Zu beachten laut OpenFreeMap: hoechstens 4 parallele
/// Anfragen, ein eigener User-Agent. Quellenangabe in der App:
/// "OpenFreeMap © OpenMapTiles, Daten von OpenStreetMap".
class OpenFreeMapTileSource implements RoadTileSource {
  OpenFreeMapTileSource(
    this._client,
    this._userAgent, {
    this.tileJsonUrl = 'https://tiles.openfreemap.org/planet',
    this.layerName = 'transportation',
    this.maxParallel = 4,
    this.cacheSize = 12,
    this.templateMaxAge = const Duration(hours: 6),
    this.timeout = const Duration(seconds: 15),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final http.Client _client;
  final String _userAgent;
  final String tileJsonUrl;
  final String layerName;
  final int maxParallel;
  final int cacheSize;
  final Duration templateMaxAge;
  final Duration timeout;
  final DateTime Function() _clock;

  String? _template;
  DateTime? _templateTime;
  Future<String>? _templateLoading;

  // LRU-Cache dekodierter Kacheln (null = leere Kachel) und laufende Abrufe.
  final LinkedHashMap<String, RoadTile?> _cache = LinkedHashMap();
  final Map<String, Future<RoadTile?>> _inflight = {};

  int _running = 0;
  final Queue<Completer<void>> _waiting = Queue();

  @override
  Future<RoadTile?> tile(int z, int x, int y) {
    final key = '$z/$x/$y';
    if (_cache.containsKey(key)) {
      final v = _cache.remove(key);
      _cache[key] = v; // ans Ende = zuletzt benutzt
      return Future.value(v);
    }
    return _inflight[key] ??= _fetch(z, x, y, key).whenComplete(() => _inflight.remove(key));
  }

  Future<RoadTile?> _fetch(int z, int x, int y, String key) async {
    await _acquire();
    try {
      final template = await _resolveTemplate();
      final url = template
          .replaceAll('{z}', '$z')
          .replaceAll('{x}', '$x')
          .replaceAll('{y}', '$y');
      final resp = await _client
          .get(Uri.parse(url), headers: {'User-Agent': _userAgent})
          .timeout(timeout);

      RoadTile? result;
      if (resp.statusCode == 204 || resp.statusCode == 404) {
        // Leer (z. B. Meer) - oder die Version hat gewechselt: beim naechsten
        // Mal frisch nachschlagen.
        if (resp.statusCode == 404) _templateTime = null;
      } else if (resp.statusCode == 200) {
        var bytes = resp.bodyBytes;
        if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
          bytes = Uint8List.fromList(gzip.decode(bytes));
        }
        final layer = decodeMvtLines(bytes, layerName);
        if (layer != null) result = RoadTile(z, x, y, layer);
      } else {
        throw http.ClientException('Kachel $key: HTTP ${resp.statusCode}');
      }

      _cache[key] = result;
      while (_cache.length > cacheSize) {
        _cache.remove(_cache.keys.first);
      }
      return result;
    } finally {
      _release();
    }
  }

  Future<String> _resolveTemplate() {
    final t = _template;
    final age = _templateTime;
    if (t != null && age != null && _clock().difference(age) < templateMaxAge) {
      return Future.value(t);
    }
    return _templateLoading ??= _loadTemplate().whenComplete(() => _templateLoading = null);
  }

  Future<String> _loadTemplate() async {
    try {
      final resp = await _client
          .get(Uri.parse(tileJsonUrl), headers: {'User-Agent': _userAgent})
          .timeout(timeout);
      if (resp.statusCode != 200) {
        throw http.ClientException('TileJSON: HTTP ${resp.statusCode}');
      }
      final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final tiles = (json['tiles'] as List?)?.cast<String>();
      if (tiles == null || tiles.isEmpty) {
        throw const FormatException('TileJSON ohne Kachel-Adresse');
      }
      if (_template != null && _template != tiles.first) _cache.clear();
      _template = tiles.first;
      _templateTime = _clock();
      return _template!;
    } catch (_) {
      // Alte Adresse weiter versuchen, falls vorhanden.
      final old = _template;
      if (old != null) {
        _templateTime = _clock().subtract(templateMaxAge - const Duration(minutes: 5));
        return old;
      }
      rethrow;
    }
  }

  Future<void> _acquire() async {
    if (_running < maxParallel) {
      _running++;
      return;
    }
    final c = Completer<void>();
    _waiting.add(c);
    await c.future; // Platz wird uebergeben, _running bleibt gleich
  }

  void _release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _running--;
    }
  }
}
