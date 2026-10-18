import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:retro_navi/core/geo.dart';
import 'package:retro_navi/core/models/gps_fix.dart';
import 'package:retro_navi/core/models/nav_route.dart';
import 'package:retro_navi/core/models/navigation_state.dart';
import 'package:retro_navi/services/mapview/map_window_builder.dart';

/// Gerade Strecke nach Norden, 10 Segmente a ~111 m (zusammen ~1000 m).
NavRoute _northRoute() => NavRoute(
      points: [for (var i = 0; i <= 9; i++) LatLng(48.0 + i * 0.001, 11.0)],
      steps: const [],
      distanceM: 1000,
      durationS: 100,
    );

double _length(NavRoute r) {
  var s = 0.0;
  for (var i = 1; i < r.points.length; i++) {
    s += haversineM(r.points[i - 1], r.points[i]);
  }
  return s;
}

NavigationState _state(
  NavRoute r,
  double along, {
  bool offRoute = false,
  double speedKmh = 50,
  double distToTurnM = 5000,
  bool active = true,
}) =>
    NavigationState(
      active: active,
      remainingM: _length(r) - along,
      speedKmh: speedKmh,
      distToTurnM: distToTurnM,
      offRoute: offRoute,
    );

final _t0 = DateTime(2026, 1, 1, 12);

void main() {
  test('Start: Chunk wird gesendet, Fahrzeug im Ursprung, Kurs Nord', () {
    final r = _northRoute();
    final b = MapWindowBuilder();
    final u = b.build(route: r, state: _state(r, 250), now: _t0)!;

    expect(u.chunk, isNotNull);
    expect(u.pose.chunkId, u.chunk!.id);
    expect(u.pose.x, closeTo(0, 0.5));
    expect(u.pose.y, closeTo(0, 0.5));
    expect(u.pose.headingDeg, 0);

    final c = u.chunk!;
    // Gerade Linie -> nach der Vereinfachung nur Anfang und Ende.
    expect(c.pointCount, 2);
    expect(c.route[0], 0); // x
    expect(c.route[1], closeTo(-150, 1)); // 150 m hinter dem Fahrzeug
    expect(c.route[3], closeTo(_length(r) - 250, 1)); // bis zum Ende der Route
    expect(c.routeEnd, isTrue);
    // Das Fahrzeug ist am Punkt 0 vorbei, der naechste Punkt (Ende) hat Index 1.
    expect(u.pose.nextIndex, 1);
  });

  test('Chunk wird nur alle 5 s wiederholt, sonst nur die Pose', () {
    final r = _northRoute();
    final b = MapWindowBuilder();
    final first = b.build(route: r, state: _state(r, 100), now: _t0)!;
    final second = b.build(
        route: r, state: _state(r, 114), now: _t0.add(const Duration(seconds: 1)))!;
    final later = b.build(
        route: r, state: _state(r, 170), now: _t0.add(const Duration(seconds: 6)))!;

    expect(first.chunk, isNotNull);
    expect(second.chunk, isNull);
    expect(second.pose.chunkId, first.chunk!.id);
    expect(later.chunk, isNotNull);
    expect(later.chunk!.id, first.chunk!.id); // gleicher Chunk, nur erneut gesendet
  });

  test('Nach 600 gefahrenen Metern kommt ein neuer Chunk mit neuer Kennung', () {
    final r = _northRoute();
    final b = MapWindowBuilder();
    final a = b.build(route: r, state: _state(r, 50), now: _t0)!;
    final c = b.build(
        route: r, state: _state(r, 700), now: _t0.add(const Duration(seconds: 1)))!;
    expect(c.chunk, isNotNull);
    expect(c.chunk!.id, isNot(a.chunk!.id));
    // Pose bezieht sich auf den neuen Chunk. Das Koordinatensystem bleibt
    // gleich (Nebenstrassen bleiben gueltig): das Fahrzeug ist 650 m weiter.
    expect(c.pose.chunkId, c.chunk!.id);
    expect(c.chunk!.frameId, a.chunk!.frameId);
    expect(c.pose.y, closeTo(650, 1.5));
  });

  test('Fahrtrichtung folgt der Strecke (Ost-Strecke = 90 Grad)', () {
    final east = NavRoute(
      points: [for (var i = 0; i <= 9; i++) LatLng(48.0, 11.0 + i * 0.0015)],
      steps: const [],
      distanceM: 1000,
      durationS: 100,
    );
    final b = MapWindowBuilder();
    final u = b.build(route: east, state: _state(east, 200), now: _t0)!;
    expect(u.pose.headingDeg, closeTo(90, 1));
  });

  test('Abseits der Route wird die echte Position gezeigt', () {
    final r = _northRoute();
    final b = MapWindowBuilder();
    // Erst auf der Route (legt den Ursprung fest) ...
    b.build(route: r, state: _state(r, 3 * 111.19), now: _t0);
    // ... dann 100 m oestlich der Strecke, Kurs 90.
    final p = offsetPoint(const LatLng(48.0 + 3 * 0.001, 11.0), 90, 100);
    final fix = GpsFix(
      lat: p.latitude,
      lng: p.longitude,
      speedMps: 10,
      heading: 90,
      accuracy: 5,
      timestamp: _t0,
    );
    final u = b.build(
        route: r,
        state: _state(r, 3 * 111.19, offRoute: true),
        fix: fix,
        now: _t0.add(const Duration(seconds: 1)))!;
    expect(u.pose.x, closeTo(100, 1.5));
    expect(u.pose.y, closeTo(0, 1.5));
    expect(u.pose.headingDeg, 90);
  });

  test('Ohne laufende Navigation: nichts', () {
    final r = _northRoute();
    final b = MapWindowBuilder();
    expect(b.build(route: r, state: _state(r, 0, active: false), now: _t0), isNull);
  });

  test('reset: der naechste Aufruf sendet den Chunk wieder', () {
    final r = _northRoute();
    final b = MapWindowBuilder();
    b.build(route: r, state: _state(r, 100), now: _t0);
    final again = b.build(
        route: r, state: _state(r, 110), now: _t0.add(const Duration(seconds: 1)))!;
    expect(again.chunk, isNull);
    b.reset();
    final after = b.build(
        route: r, state: _state(r, 120), now: _t0.add(const Duration(seconds: 2)))!;
    expect(after.chunk, isNotNull);
  });

  test('neue Route (Neuberechnung) -> neuer Chunk', () {
    final r1 = _northRoute();
    final r2 = _northRoute(); // gleiche Form, aber anderes Objekt
    final b = MapWindowBuilder();
    final a = b.build(route: r1, state: _state(r1, 100), now: _t0)!;
    final c = b.build(
        route: r2, state: _state(r2, 110), now: _t0.add(const Duration(seconds: 1)))!;
    expect(c.chunk, isNotNull);
    expect(c.chunk!.id, isNot(a.chunk!.id));
  });

  test('Koordinatensystem: eines pro Fahrt, reset und grosse Entfernung geben ein neues', () {
    final r = _northRoute();
    final b = MapWindowBuilder();
    final a = b.build(route: r, state: _state(r, 100), now: _t0)!;
    expect(a.chunk!.frameId, greaterThan(0));
    expect(a.window!.frameId, a.chunk!.frameId);
    expect(a.window!.xs.length, a.window!.alongs.length);
    expect(a.window!.vehicleAlong, closeTo(100, 0.01));

    b.reset();
    final after = b.build(
        route: r, state: _state(r, 120), now: _t0.add(const Duration(seconds: 1)))!;
    expect(after.chunk!.frameId, isNot(a.chunk!.frameId));

    // Sehr kleine Grenze: schon nach wenigen Metern neues System.
    final small = MapWindowBuilder(reoriginM: 50);
    final s1 = small.build(route: r, state: _state(r, 100), now: _t0)!;
    final s2 = small.build(
        route: r, state: _state(r, 300), now: _t0.add(const Duration(seconds: 1)))!;
    expect(s2.chunk!.frameId, isNot(s1.chunk!.frameId));
    expect(s2.pose.y, closeTo(0, 0.5));
  });

  test('lange kurvige Strecke bleibt unter der Punktgrenze', () {
    // 3 km Zickzack mit Punkten alle ~10 m.
    final pts = <LatLng>[];
    for (var i = 0; i < 300; i++) {
      pts.add(LatLng(48.0 + i * 0.00009, 11.0 + (i % 20 < 10 ? i % 10 : 10 - i % 10) * 0.00006));
    }
    final r = NavRoute(points: pts, steps: const [], distanceM: 3000, durationS: 300);
    final b = MapWindowBuilder(maxPoints: 20);
    final u = b.build(route: r, state: _state(r, 100), now: _t0)!;
    expect(u.chunk!.pointCount, lessThanOrEqualTo(20));
    expect(u.chunk!.pointCount, greaterThanOrEqualTo(2));
  });
}
