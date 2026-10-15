import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../core/geo.dart';

/// Faehrt eine Linie virtuell ab: Strecke rein, Position und Kurs raus.
/// Reine Logik ohne Timer, daher leicht testbar.
class RoutePlayback {
  RoutePlayback(List<LatLng> points) : _pts = List.unmodifiable(points) {
    if (points.length < 2) {
      throw ArgumentError('Mindestens 2 Punkte noetig.');
    }
    _cum = List<double>.filled(points.length, 0);
    for (var i = 1; i < points.length; i++) {
      _cum[i] = _cum[i - 1] + haversineM(points[i - 1], points[i]);
    }
  }

  final List<LatLng> _pts;
  late final List<double> _cum;
  double _progress = 0;

  double get totalM => _cum.last;
  double get progressM => _progress;
  bool get finished => _progress >= totalM - 0.01;

  void advance(double meters) {
    _progress = math.min(totalM, _progress + math.max(0.0, meters));
  }

  void reset() => _progress = 0;

  /// Index des Segments, in dem die aktuelle Strecke liegt.
  int _segment() {
    var lo = 0;
    var hi = _pts.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_cum[mid] <= _progress) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  LatLng get position {
    final i = _segment();
    final len = _cum[i + 1] - _cum[i];
    final t = len <= 0 ? 0.0 : math.min(1.0, math.max(0.0, (_progress - _cum[i]) / len));
    final a = _pts[i];
    final b = _pts[i + 1];
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Kurs in Grad. Sehr kurze Segmente (< 1 m) werden uebersprungen,
  /// damit der Kurs bei doppelten Punkten nicht springt.
  double get heading {
    final i = _segment();
    var j = i;
    while (j < _pts.length - 2 && _cum[j + 1] - _cum[j] < 1) {
      j++;
    }
    if (_cum[j + 1] - _cum[j] < 1) {
      j = i;
      while (j > 0 && _cum[j + 1] - _cum[j] < 1) {
        j--;
      }
    }
    return bearingDeg(_pts[j], _pts[j + 1]);
  }
}
