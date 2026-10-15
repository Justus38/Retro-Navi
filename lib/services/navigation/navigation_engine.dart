import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../core/models/gps_fix.dart';
import '../../core/models/nav_route.dart';
import '../../core/models/navigation_state.dart';

/// Reine Dart-Logik ohne Flutter/Riverpod: Position rein, NavigationState raus.
/// Eine Engine gehoert zu genau einer Route; bei neuer Route neue Engine.
class NavigationEngine {
  NavigationEngine(
    this.route, {
    this.offRouteThresholdM = 50,
    this.arrivalRadiusM = 25,
  }) {
    final pts = route.points;
    if (pts.length < 2) {
      throw ArgumentError('Route braucht mindestens 2 Punkte.');
    }
    _cum = List<double>.filled(pts.length, 0);
    for (var i = 1; i < pts.length; i++) {
      _cum[i] = _cum[i - 1] + _haversine(pts[i - 1], pts[i]);
    }
    final steps = route.steps;
    _stepAlong = [for (final s in steps) _alongAt(s.startIndex)];
    _stepEnd = [for (final s in steps) _alongAt(s.endIndex)];
    // Summe der Dauer aller Schritte NACH Schritt k.
    _durAfter = List<double>.filled(steps.length, 0);
    for (var k = steps.length - 2; k >= 0; k--) {
      _durAfter[k] = _durAfter[k + 1] + steps[k + 1].durationS;
    }
  }

  final NavRoute route;

  /// Abweichung, ab der man als "von der Route ab" gilt.
  final double offRouteThresholdM;

  /// Restdistanz, ab der man als angekommen gilt.
  final double arrivalRadiusM;

  static const _searchWindowM = 1000.0;
  static const _mPerDeg = 111194.9266; // 6371008.8 m * pi / 180

  late final List<double> _cum;
  late final List<double> _stepAlong;
  late final List<double> _stepEnd;
  late final List<double> _durAfter;

  int _seg = 0;
  int _step = 0;
  int _offCount = 0;
  double _progress = 0;
  double _lastDist = 0;

  double _alongAt(int index) =>
      _cum[math.max(0, math.min(index, _cum.length - 1))];

  /// Verarbeitet einen GPS-Fix und liefert den aktuellen Navigationszustand.
  NavigationState update(GpsFix fix) {
    final p = fix.latLng;
    // Bei schlechter GPS-Genauigkeit etwas grosszuegiger (max. doppelt).
    final threshold = math.min(
      math.max(offRouteThresholdM, fix.accuracy),
      2 * offRouteThresholdM,
    );

    // 1) Zuerst nur im Bereich vor/hinter der letzten Position suchen ...
    var m = _matchWindow(p);
    var jumped = false;
    // 2) ... und nur bei grossem Abstand auf der ganzen Route.
    if (m.distM > threshold) {
      final g = _matchGlobal(p);
      if (g.distM < m.distM) {
        m = g;
        jumped = g.distM <= threshold;
      }
    }

    _lastDist = m.distM;
    if (m.distM <= threshold) {
      _offCount = 0;
      _seg = m.seg;
      _progress = m.alongM;
      if (jumped) _step = 0; // nach Sprung Schritt neu bestimmen
      while (_step + 1 < route.steps.length &&
          _stepAlong[_step + 1] <= _progress) {
        _step++;
      }
    } else {
      _offCount++; // Position und Schritt bleiben auf dem letzten Stand
    }

    return _build(fix);
  }

  NavigationState _build(GpsFix fix) {
    final steps = route.steps;
    final total = _cum.last;
    final remainingM = math.max(0.0, total - _progress);
    final offRoute = _offCount >= 2; // 2 Fixes in Folge gegen GPS-Ausreisser
    final arrived = !offRoute && remainingM <= arrivalRadiusM;

    if (steps.isEmpty) {
      return NavigationState(
        active: true,
        turn: TurnType.goal,
        distToTurnM: arrived ? 0 : remainingM,
        remainingM: remainingM,
        remainingS: arrived || total <= 0
            ? 0
            : route.durationS * (remainingM / total),
        speedKmh: fix.speedKmh,
        offRouteM: _lastDist,
        offRoute: offRoute,
        arrived: arrived,
      );
    }

    final cur = steps[_step];
    final nextIdx = math.min(_step + 1, steps.length - 1);
    final next = steps[nextIdx];

    final segLen = _stepEnd[_step] - _stepAlong[_step];
    final left = segLen <= 0
        ? 0.0
        : math.max(0.0, math.min(1.0, (_stepEnd[_step] - _progress) / segLen));

    return NavigationState(
      active: true,
      turn: arrived ? TurnType.goal : next.type,
      instruction: next.instruction,
      distToTurnM:
          arrived ? 0 : math.max(0.0, _stepAlong[nextIdx] - _progress),
      street: next.streetName.isNotEmpty ? next.streetName : cur.streetName,
      exitNumber: next.exitNumber,
      remainingM: remainingM,
      remainingS: arrived ? 0 : left * cur.durationS + _durAfter[_step],
      speedKmh: fix.speedKmh,
      stepIndex: nextIdx,
      offRouteM: _lastDist,
      offRoute: offRoute,
      arrived: arrived,
    );
  }

  _Match _matchWindow(LatLng p) {
    final pts = route.points;
    _Match? best;
    for (var i = math.max(0, _seg - 2); i < pts.length - 1; i++) {
      if (i > _seg && _cum[i] - _cum[_seg] > _searchWindowM) break;
      final c = _project(p, i);
      if (best == null || c.distM < best.distM) best = c;
    }
    return best!;
  }

  _Match _matchGlobal(LatLng p) {
    _Match? best;
    for (var i = 0; i < route.points.length - 1; i++) {
      final c = _project(p, i);
      if (best == null || c.distM < best.distM) best = c;
    }
    return best!;
  }

  /// Naechster Punkt auf Segment i (lokale ebene Naeherung, genau genug fuer
  /// Abstaende im Bereich weniger hundert Meter).
  _Match _project(LatLng p, int i) {
    final a = route.points[i];
    final b = route.points[i + 1];
    final ky = _mPerDeg;
    final kx = _mPerDeg * math.cos(_rad(p.latitude));
    final ax = (a.longitude - p.longitude) * kx;
    final ay = (a.latitude - p.latitude) * ky;
    final bx = (b.longitude - p.longitude) * kx;
    final by = (b.latitude - p.latitude) * ky;
    final dx = bx - ax;
    final dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
    t = math.max(0.0, math.min(1.0, t));
    final cx = ax + t * dx;
    final cy = ay + t * dy;
    return _Match(i, math.sqrt(cx * cx + cy * cy), _cum[i] + t * (_cum[i + 1] - _cum[i]));
  }

  static double _rad(double deg) => deg * math.pi / 180;

  static double _haversine(LatLng a, LatLng b) {
    const r = 6371008.8;
    final dLat = _rad(b.latitude - a.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final s1 = math.sin(dLat / 2);
    final s2 = math.sin(dLon / 2);
    final h = s1 * s1 +
        math.cos(_rad(a.latitude)) * math.cos(_rad(b.latitude)) * s2 * s2;
    return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
  }
}

class _Match {
  const _Match(this.seg, this.distM, this.alongM);
  final int seg;
  final double distM;
  final double alongM;
}
