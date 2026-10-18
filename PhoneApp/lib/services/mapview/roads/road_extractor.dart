import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../local_frame.dart';
import '../route_simplifier.dart';
import 'road_models.dart';
import 'tile_math.dart';

/// Macht aus Vektorkacheln die Strassen neben der Route.
///
/// - Nur Strassen innerhalb von [corridorM] Metern um den Routenabschnitt.
/// - Punkte näher als [onRouteM] an der Route entfallen: die Route selbst
///   wird ohnehin gezeichnet, so gibt es keine doppelten Linien.
/// - Linien werden vereinfacht, zu kurze Stuecke verworfen und die Gesamt-
///   zahl der Punkte begrenzt (Hauptstrassen und Naehe zum Fahrzeug zuerst).
class RoadExtractor {
  const RoadExtractor({
    this.corridorM = 260,
    this.onRouteM = 8,
    this.simplifyM = 3,
    this.minRunLengthM = 20,
    this.maxPoints = 2400,
    this.maxRuns = 400,
    this.maxRunPoints = 60,
    this.densifyM = 30,
  });

  final double corridorM;
  final double onRouteM;
  final double simplifyM;
  final double minRunLengthM;
  final int maxPoints;
  final int maxRuns;
  final int maxRunPoints;

  /// Lange gerade Stuecke werden vor der Auswahl in Schritte dieser Laenge
  /// zerlegt, sonst fielen Strassen mit nur zwei Punkten (Anfang an der Route,
  /// Ende weit draussen) komplett heraus.
  final double densifyM;

  /// [routeXs]/[routeYs]: Routenabschnitt im Koordinatensystem [frame].
  List<RoadRun> extract({
    required List<RoadTile> tiles,
    required LocalFrame frame,
    required List<double> routeXs,
    required List<double> routeYs,
    required double vehicleX,
    required double vehicleY,
  }) {
    if (routeXs.length < 2) return const [];

    // Route grob vereinfachen: spart Rechenzeit beim Abstand (Fehler <= 8 m,
    // fuer den 260-m-Korridor unerheblich).
    final keep = douglasPeucker(routeXs, routeYs, 8);
    final rx = [for (final i in keep) routeXs[i]];
    final ry = [for (final i in keep) routeYs[i]];
    final minX = rx.reduce(math.min) - corridorM;
    final maxX = rx.reduce(math.max) + corridorM;
    final minY = ry.reduce(math.min) - corridorM;
    final maxY = ry.reduce(math.max) + corridorM;

    final found = <_Found>[];
    for (final t in tiles) {
      final ext = t.layer.extent;
      for (final line in t.layer.lines) {
        final cls = roadClassCode(line.roadClass);
        if (cls == 0) continue;
        final c = line.coords;
        final n = c.length ~/ 2;
        final px = List<double>.filled(n, 0);
        final py = List<double>.filled(n, 0);
        var lx0 = double.infinity, lx1 = -double.infinity;
        var ly0 = double.infinity, ly1 = -double.infinity;
        for (var i = 0; i < n; i++) {
          final p = LatLng(
            tileLat(t.y, c[2 * i + 1].toDouble(), ext, t.z),
            tileLon(t.x, c[2 * i].toDouble(), ext, t.z),
          );
          final x = frame.x(p);
          final y = frame.y(p);
          px[i] = x;
          py[i] = y;
          lx0 = math.min(lx0, x);
          lx1 = math.max(lx1, x);
          ly0 = math.min(ly0, y);
          ly1 = math.max(ly1, y);
        }
        if (lx1 < minX || lx0 > maxX || ly1 < minY || ly0 > maxY) continue;
        _splitLine(cls, px, py, rx, ry, vehicleX, vehicleY, found);
      }
    }

    // Wichtigstes zuerst: Hauptstrassen, dann nach Naehe zum Fahrzeug.
    found.sort((a, b) {
      if (a.run.cls != b.run.cls) return b.run.cls - a.run.cls;
      return a.dist.compareTo(b.dist);
    });
    final out = <RoadRun>[];
    var points = 0;
    for (final f in found) {
      if (out.length >= maxRuns) break;
      if (points + f.run.pointCount > maxPoints) continue;
      out.add(f.run);
      points += f.run.pointCount;
    }
    return out;
  }

  void _splitLine(
    int cls,
    List<double> px,
    List<double> py,
    List<double> rx,
    List<double> ry,
    double vx,
    double vy,
    List<_Found> out,
  ) {
    var runX = <double>[];
    var runY = <double>[];

    void flush() {
      if (runX.length >= 2) _finishRun(cls, runX, runY, vx, vy, out);
      runX = <double>[];
      runY = <double>[];
    }

    void visit(double x, double y) {
      final d = _distToPolyline(x, y, rx, ry);
      if (d > onRouteM && d <= corridorM) {
        runX.add(x);
        runY.add(y);
      } else {
        flush();
      }
    }

    visit(px[0], py[0]);
    for (var i = 1; i < px.length; i++) {
      final dx = px[i] - px[i - 1];
      final dy = py[i] - py[i - 1];
      final steps = math.max(1, (math.sqrt(dx * dx + dy * dy) / densifyM).ceil());
      for (var k = 1; k <= steps; k++) {
        final t = k / steps;
        visit(px[i - 1] + dx * t, py[i - 1] + dy * t);
      }
    }
    flush();
  }

  void _finishRun(int cls, List<double> xs, List<double> ys, double vx, double vy,
      List<_Found> out) {
    final idx = douglasPeucker(xs, ys, simplifyM);
    // Ganze Meter, direkte Doppelpunkte entfernen.
    final pts = <int>[];
    for (final i in idx) {
      final x = xs[i].round();
      final y = ys[i].round();
      final n = pts.length;
      if (n >= 2 && pts[n - 2] == x && pts[n - 1] == y) continue;
      pts
        ..add(x)
        ..add(y);
    }
    if (pts.length < 4) return;

    var len = 0.0;
    for (var i = 2; i < pts.length; i += 2) {
      len += math.sqrt(math.pow(pts[i] - pts[i - 2], 2) + math.pow(pts[i + 1] - pts[i - 1], 2));
    }
    if (len < minRunLengthM) return;

    // In Stuecke zu hoechstens maxRunPoints Punkten teilen (Endpunkt doppelt,
    // damit die Linie zusammenhaengt).
    var start = 0;
    final total = pts.length ~/ 2;
    while (start < total - 1) {
      final end = math.min(total, start + maxRunPoints);
      final piece = pts.sublist(2 * start, 2 * end);
      final mx = piece[piece.length ~/ 2 & ~1] - vx;
      final my = piece[(piece.length ~/ 2 & ~1) + 1] - vy;
      out.add(_Found(RoadRun(cls, piece), math.sqrt(mx * mx + my * my)));
      if (end >= total) break;
      start = end - 1;
    }
  }

  static double _distToPolyline(double x, double y, List<double> xs, List<double> ys) {
    var best = double.infinity;
    for (var i = 1; i < xs.length; i++) {
      final d = _distToSegment(x, y, xs[i - 1], ys[i - 1], xs[i], ys[i]);
      if (d < best) best = d;
    }
    return best;
  }

  static double _distToSegment(
      double px, double py, double ax, double ay, double bx, double by) {
    final dx = bx - ax;
    final dy = by - ay;
    final l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / l2;
    t = t.clamp(0.0, 1.0).toDouble();
    final cx = ax + t * dx - px;
    final cy = ay + t * dy - py;
    return math.sqrt(cx * cx + cy * cy);
  }
}

class _Found {
  const _Found(this.run, this.dist);
  final RoadRun run;
  final double dist;
}
