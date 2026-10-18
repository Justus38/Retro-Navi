import 'dart:async';
import 'dart:math' as math;

import '../../encoder/esp32_encoder.dart';
import '../map_models.dart';
import 'road_extractor.dart';
import 'road_models.dart';
import 'tile_math.dart';

/// Liefert die Nebenstrassen-Nachrichten fuer den ESP32, Stueck fuer Stueck.
///
/// Der Aufrufer (OutputScheduler) fragt einmal pro Sekunde [next]. Das
/// Laden der Kacheln laeuft im Hintergrund; bis die Strassen fertig sind,
/// kommt eine leere Liste zurueck. Fertige Strassen werden in kleinen Teilen
/// (hoechstens [partsPerTick] pro Aufruf) ausgeliefert und alle [resendEvery]
/// wiederholt, falls der ESP32 etwas verpasst hat.
class RoadStreamer {
  RoadStreamer({
    required this.source,
    required this.encoder,
    this.extractor = const RoadExtractor(),
    this.onError,
    this.zoom = 14,
    this.aheadM = 1200,
    this.behindM = 200,
    this.rebuildAfterM = 400,
    this.partsPerTick = 2,
    this.resendEvery = const Duration(seconds: 40),
    this.retryAfter = const Duration(seconds: 15),
  });

  final RoadTileSource source;
  final Esp32Encoder encoder;
  final RoadExtractor extractor;
  final void Function(Object error)? onError;
  final int zoom;

  /// Wie viel Strecke voraus / zurueck Strassen geladen werden.
  final double aheadM;
  final double behindM;

  /// Nach so vielen gefahrenen Metern (oder neuem Chunk) neu zusammenstellen.
  final double rebuildAfterM;
  final int partsPerTick;
  final Duration resendEvery;
  final Duration retryAfter;

  int _generation = 0;
  int _frameId = 0;
  int _builtChunkId = -1;
  double _builtAlong = 0;
  bool _loading = false;
  DateTime? _retryAt;
  DateTime? _enqueued;
  List<String> _current = const [];
  final List<String> _queue = [];
  int _session = 0; // ungueltig machen, falls waehrend des Ladens reset()
  bool _sentAny = false;

  /// Alles vergessen (Navigation beendet / Kartenansicht aus).
  void reset() {
    _session++;
    _frameId = 0;
    _builtChunkId = -1;
    _loading = false;
    _retryAt = null;
    _enqueued = null;
    _current = const [];
    _queue.clear();
    _sentAny = false;
  }

  /// Nachrichten fuer diesen Takt (hoechstens [partsPerTick]).
  /// [enabled] = false: einmal die Strassen loeschen, danach Ruhe.
  List<String> next(MapUpdate update, {required DateTime now, bool enabled = true}) {
    final w = update.window;
    if (w == null) return const [];

    if (!enabled) {
      _session++;
      _loading = false;
      _queue.clear();
      _current = const [];
      _builtChunkId = -1;
      if (_sentAny) {
        _sentAny = false;
        return [_clearMessage(w.frameId)];
      }
      return const [];
    }

    if (w.frameId != _frameId) {
      // Neues Koordinatensystem: alte Strassen sind ungueltig (der ESP32
      // verwirft sie mit dem ersten Chunk des neuen Systems).
      _session++;
      _frameId = w.frameId;
      _builtChunkId = -1;
      _loading = false;
      _queue.clear();
      _current = const [];
      _sentAny = false;
    }

    final needBuild = _builtChunkId != w.chunkId ||
        (w.vehicleAlong - _builtAlong).abs() >= rebuildAfterM;
    if (needBuild && !_loading && (_retryAt == null || !now.isBefore(_retryAt!))) {
      _loading = true;
      final session = _session;
      unawaited(_build(w, now, session));
    }

    // Wiederholen, wenn alles gesendet und lange nichts mehr kam.
    if (_queue.isEmpty &&
        _current.isNotEmpty &&
        _enqueued != null &&
        now.difference(_enqueued!) >= resendEvery) {
      _queue.addAll(_current);
      _enqueued = now;
    }

    final n = math.min(partsPerTick, _queue.length);
    if (n == 0) return const [];
    final out = _queue.sublist(0, n);
    _queue.removeRange(0, n);
    _sentAny = true;
    return out;
  }

  Future<void> _build(MapWindow w, DateTime now, int session) async {
    try {
      // Routenabschnitt um das Fahrzeug.
      var lo = w.xs.length;
      var hi = -1;
      for (var i = 0; i < w.xs.length; i++) {
        final a = w.alongs[i];
        if (a >= w.vehicleAlong - behindM && a <= w.vehicleAlong + aheadM) {
          if (i < lo) lo = i;
          hi = i;
        }
      }
      if (hi < 0) {
        lo = 0;
        hi = w.xs.length - 1;
      } else {
        // Einen Punkt mehr an jedem Ende, damit lange Geraden nicht abreissen.
        lo = math.max(0, lo - 1);
        hi = math.min(w.xs.length - 1, hi + 1);
      }
      final xs = w.xs.sublist(lo, hi + 1);
      final ys = w.ys.sublist(lo, hi + 1);
      if (xs.length < 2) throw StateError('Routenabschnitt zu kurz');

      // Welche Kacheln beruehren Strecke + Korridor?
      final margin = extractor.corridorM;
      final minX = xs.reduce(math.min) - margin;
      final maxX = xs.reduce(math.max) + margin;
      final minY = ys.reduce(math.min) - margin;
      final maxY = ys.reduce(math.max) + margin;
      final sw = w.frame.latLngAt(minX, minY);
      final ne = w.frame.latLngAt(maxX, maxY);
      final x0 = tileX(sw.longitude, zoom);
      final x1 = tileX(ne.longitude, zoom);
      final y0 = tileY(ne.latitude, zoom);
      final y1 = tileY(sw.latitude, zoom);
      if ((x1 - x0 + 1) * (y1 - y0 + 1) > 16) {
        throw StateError('Zu viele Kacheln fuer den Routenabschnitt');
      }

      final futures = <Future<RoadTile?>>[
        for (var ty = y0; ty <= y1; ty++)
          for (var tx = x0; tx <= x1; tx++) source.tile(zoom, tx, ty),
      ];
      final tiles = [
        for (final t in await Future.wait(futures))
          if (t != null) t
      ];
      if (session != _session) return;

      final pose = _vehicleXY(w);
      final runs = extractor.extract(
        tiles: tiles,
        frame: w.frame,
        routeXs: xs,
        routeYs: ys,
        vehicleX: pose.$1,
        vehicleY: pose.$2,
      );
      if (session != _session) return;

      _generation = _generation >= 9999 ? 1 : _generation + 1;
      _current = encoder.encodeRoadParts(
        runs,
        frameId: w.frameId,
        generation: _generation,
      );
      _queue
        ..clear()
        ..addAll(_current);
      _enqueued = now;
      _builtChunkId = w.chunkId;
      _builtAlong = w.vehicleAlong;
      _retryAt = null;
    } catch (e) {
      if (session != _session) return;
      _retryAt = now.add(retryAfter);
      onError?.call(e);
    } finally {
      if (session == _session) _loading = false;
    }
  }

  /// Fahrzeugposition (Naeherung: Punkt der Strecke bei vehicleAlong).
  (double, double) _vehicleXY(MapWindow w) {
    for (var i = 1; i < w.alongs.length; i++) {
      if (w.alongs[i] >= w.vehicleAlong) {
        final span = w.alongs[i] - w.alongs[i - 1];
        final t = span <= 0 ? 0.0 : (w.vehicleAlong - w.alongs[i - 1]) / span;
        return (
          w.xs[i - 1] + (w.xs[i] - w.xs[i - 1]) * t,
          w.ys[i - 1] + (w.ys[i] - w.ys[i - 1]) * t,
        );
      }
    }
    return (w.xs.last, w.ys.last);
  }

  String _clearMessage(int frameId) {
    _generation = _generation >= 9999 ? 1 : _generation + 1;
    return encoder.encodeRoadParts(const [], frameId: frameId, generation: _generation).single;
  }
}
