import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../core/geo.dart';
import '../../core/models/gps_fix.dart';
import '../../core/models/nav_route.dart';
import '../../core/models/navigation_state.dart';
import 'local_frame.dart';
import 'map_models.dart';
import 'route_simplifier.dart';
import 'zoom_policy.dart';

/// Baut aus Route und Navigationszustand die Kartendaten fuer den ESP32.
///
/// Rein Dart, ohne Flutter und Riverpod. Der Aufrufer (OutputScheduler) ruft
/// [build] einmal pro Sekunde auf.
///
/// - Das Fahrzeug wird auf die Route "eingerastet" (kein GPS-Zittern); die
///   Fahrtrichtung ist die Richtung der Strecke ca. [lookaheadM] voraus.
/// - Weicht man von der Route ab, wird die echte Position gezeigt.
/// - Der Chunk (Strecke voraus) wird erst nach [refreshAfterM] gefahrenen
///   Metern neu gebaut, sonst nur alle [resendEvery] erneut gesendet, falls
///   der ESP32 ihn verpasst hat (z. B. nach einem Verbindungsabbruch).
class MapWindowBuilder {
  MapWindowBuilder({
    this.behindM = 150,
    this.aheadM = 2500,
    this.refreshAfterM = 600,
    this.resendEvery = const Duration(seconds: 5),
    this.maxPoints = 80,
    this.simplifyToleranceM = 2.5,
    this.lookaheadM = 20,
    this.zoom = const ZoomPolicy(),
    this.reoriginM = 20000,
  });

  /// Entfernt sich das Fahrzeug so weit vom Ursprung, beginnt ein neues
  /// Koordinatensystem (Zahlen bleiben klein, Nebenstrassen werden neu geladen).
  final double reoriginM;

  /// Wie viel Strecke hinter dem Fahrzeug im Chunk bleibt.
  final double behindM;

  /// Wie viel Strecke voraus im Chunk steckt.
  final double aheadM;

  /// Nach so vielen gefahrenen Metern wird ein neuer Chunk gebaut.
  final double refreshAfterM;
  final Duration resendEvery;

  /// Obergrenze der Punktzahl (haelt die Nachricht klein).
  final int maxPoints;
  final double simplifyToleranceM;
  final double lookaheadM;
  final ZoomPolicy zoom;

  NavRoute? _route;
  List<double> _cum = const [];
  _ChunkInfo? _chunk;
  LocalFrame? _frame;
  int _frameId = 0;
  DateTime? _lastSent;
  int _lastId = 0;
  double? _prevHeading;
  int? _prevZoom;

  /// Alles vergessen (z. B. Navigation beendet). Der naechste [build] baut
  /// einen frischen Chunk und sendet ihn.
  void reset() {
    _route = null;
    _cum = const [];
    _chunk = null;
    _frame = null; // naechstes Mal neues Koordinatensystem (neue Kennung)
    _lastSent = null;
    _prevHeading = null;
    _prevZoom = null;
  }

  /// Liefert null, wenn keine Navigation laeuft oder die Route unbrauchbar ist.
  MapUpdate? build({
    required NavRoute route,
    required NavigationState state,
    GpsFix? fix,
    required DateTime now,
  }) {
    if (!state.active || route.points.length < 2) return null;
    if (!identical(route, _route)) _useRoute(route);

    final total = _cum.last;
    if (total <= 0) return null;
    final along = (total - state.remainingM).clamp(0.0, total).toDouble();

    // Fahrzeugposition und Richtung.
    final LatLng pos;
    final double heading;
    if (state.offRoute && fix != null) {
      pos = fix.latLng;
      heading = fix.hasHeading ? fix.heading : (_prevHeading ?? _routeHeading(along, total));
    } else {
      pos = _pointAt(along);
      heading = _routeHeading(along, total);
    }
    _prevHeading = heading;

    // Koordinatensystem: eines pro Fahrt, bei grosser Entfernung ein neues.
    var frame = _frame;
    if (frame == null ||
        haversineM(frame.origin, pos) > reoriginM) {
      frame = LocalFrame(pos);
      _frame = frame;
      _frameId = _frameId >= 9999 ? 1 : _frameId + 1;
      _chunk = null;
    }

    // Chunk neu bauen?
    var chunk = _chunk;
    var needNew = false;
    if (chunk == null ||
        along < chunk.startAlong ||
        along - chunk.anchorAlong >= refreshAfterM) {
      chunk = _buildChunk(along, total, frame);
      _chunk = chunk;
      needNew = true;
    }
    final send = needNew ||
        _lastSent == null ||
        now.difference(_lastSent!) >= resendEvery;
    if (send) _lastSent = now;

    // Pose im Koordinatensystem des Chunks.
    var nextIdx = chunk.alongs.length - 1;
    for (var i = 0; i < chunk.alongs.length; i++) {
      if (chunk.alongs[i] > along + 0.01) {
        nextIdx = i;
        break;
      }
    }

    final z = zoom.next(
      previous: _prevZoom,
      speedKmh: state.speedKmh,
      distToTurnM: state.distToTurnM,
    );
    _prevZoom = z;

    final pose = MapPose(
      chunkId: chunk.data.id,
      x: frame.x(pos),
      y: frame.y(pos),
      headingDeg: _normalizeDeg(heading),
      zoomM: z,
      nextIndex: nextIdx,
    );
    return MapUpdate(
      chunk: send ? chunk.data : null,
      pose: pose,
      window: MapWindow(
        frame: frame,
        frameId: _frameId,
        chunkId: chunk.data.id,
        xs: chunk.xs,
        ys: chunk.ys,
        alongs: chunk.allAlongs,
        vehicleAlong: along,
      ),
    );
  }

  // ------------------------------------------------------------ Chunk

  _ChunkInfo _buildChunk(double along, double total, LocalFrame frame) {
    final pts = _route!.points;
    final startAlong = math.max(0.0, along - behindM);
    final endAlong = math.min(total, along + aheadM);

    final ptsLL = <LatLng>[_pointAt(startAlong)];
    final alongs = <double>[startAlong];
    for (var i = _segmentIndex(startAlong) + 1; i < pts.length; i++) {
      final c = _cum[i];
      if (c >= endAlong) break;
      if (c > startAlong) {
        ptsLL.add(pts[i]);
        alongs.add(c);
      }
    }
    ptsLL.add(_pointAt(endAlong));
    alongs.add(endAlong);

    final xs = [for (final p in ptsLL) frame.x(p)];
    final ys = [for (final p in ptsLL) frame.y(p)];
    final kept = simplifyToMax(xs, ys,
        maxPoints: maxPoints, startTolerance: simplifyToleranceM);

    // In ganze Meter runden, aufeinanderfolgende Duplikate entfernen.
    final flat = <int>[];
    final keptAlongs = <double>[];
    for (final i in kept) {
      final rx = xs[i].round();
      final ry = ys[i].round();
      final n = flat.length;
      if (n >= 2 && flat[n - 2] == rx && flat[n - 1] == ry) continue;
      flat
        ..add(rx)
        ..add(ry);
      keptAlongs.add(alongs[i]);
    }

    _lastId = _lastId >= 9999 ? 1 : _lastId + 1;
    return _ChunkInfo(
      data: MapChunk(
        id: _lastId,
        route: flat,
        routeEnd: endAlong >= total - 0.5,
        frameId: _frameId,
      ),
      xs: xs,
      ys: ys,
      allAlongs: alongs,
      startAlong: startAlong,
      anchorAlong: along,
      alongs: keptAlongs,
    );
  }

  // --------------------------------------------------------- Geometrie

  void _useRoute(NavRoute route) {
    _route = route;
    final pts = route.points;
    final cum = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      cum[i] = cum[i - 1] + haversineM(pts[i - 1], pts[i]);
    }
    _cum = cum;
    _chunk = null;
    _lastSent = null;
    _prevHeading = null;
  }

  /// Index i des Segments (i, i+1), in dem die Strecke [s] liegt.
  int _segmentIndex(double s) {
    var lo = 0;
    var hi = _cum.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_cum[mid] <= s) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  LatLng _pointAt(double s) {
    final pts = _route!.points;
    final i = _segmentIndex(s);
    final len = _cum[i + 1] - _cum[i];
    final t = len <= 0 ? 0.0 : ((s - _cum[i]) / len).clamp(0.0, 1.0).toDouble();
    final a = pts[i];
    final b = pts[i + 1];
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Richtung der Strecke ab [along] ca. [lookaheadM] voraus. Kurz vor dem Ende
  /// bleibt es die Richtung der Schlussstrecke.
  double _routeHeading(double along, double total) {
    final a = math.max(0.0, math.min(along, total - lookaheadM));
    final p0 = _pointAt(a);
    final p1 = _pointAt(math.min(total, a + lookaheadM));
    if (haversineM(p0, p1) < 1.0) return _prevHeading ?? 0;
    return bearingDeg(p0, p1);
  }

  static int _normalizeDeg(double deg) {
    final d = deg.isFinite ? deg.round() : 0;
    return ((d % 360) + 360) % 360;
  }
}

class _ChunkInfo {
  const _ChunkInfo({
    required this.data,
    required this.xs,
    required this.ys,
    required this.allAlongs,
    required this.startAlong,
    required this.anchorAlong,
    required this.alongs,
  });

  final MapChunk data;

  /// Chunk-Strecke in voller Aufloesung (vor der Vereinfachung).
  final List<double> xs;
  final List<double> ys;
  final List<double> allAlongs;

  /// Streckenmeter des ersten Chunk-Punkts.
  final double startAlong;

  /// Streckenmeter des Fahrzeugs beim Bau des Chunks.
  final double anchorAlong;

  /// Streckenmeter jedes Chunk-Punkts (gleiche Reihenfolge wie data.route).
  final List<double> alongs;
}
