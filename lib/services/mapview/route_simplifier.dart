import 'dart:math' as math;

/// Douglas-Peucker: liefert die Indizes der behaltenen Punkte (aufsteigend).
/// Erster und letzter Punkt bleiben immer erhalten. Keine Rekursion, damit
/// auch lange Linien nicht den Stack sprengen.
List<int> douglasPeucker(List<double> xs, List<double> ys, double tolerance) {
  final n = xs.length;
  if (n <= 2) return [for (var i = 0; i < n; i++) i];

  final keep = List<bool>.filled(n, false);
  keep[0] = true;
  keep[n - 1] = true;

  final stack = <(int, int)>[(0, n - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var maxD = -1.0;
    var idx = -1;
    for (var i = a + 1; i < b; i++) {
      final d = _segmentDistance(xs[i], ys[i], xs[a], ys[a], xs[b], ys[b]);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx != -1 && maxD > tolerance) {
      keep[idx] = true;
      stack.add((a, idx));
      stack.add((idx, b));
    }
  }
  return [
    for (var i = 0; i < n; i++)
      if (keep[i]) i
  ];
}

/// Vereinfacht so lange mit wachsender Toleranz, bis hoechstens [maxPoints]
/// Punkte uebrig sind. Die Genauigkeit sinkt nur, wenn es sein muss.
List<int> simplifyToMax(
  List<double> xs,
  List<double> ys, {
  required int maxPoints,
  double startTolerance = 2.5,
}) {
  var tol = startTolerance;
  var kept = douglasPeucker(xs, ys, tol);
  var guard = 0;
  while (kept.length > maxPoints && guard++ < 30) {
    tol *= 1.5;
    kept = douglasPeucker(xs, ys, tol);
  }
  if (kept.length > maxPoints) {
    // Notbremse (praktisch unerreichbar): gleichmaessig ausduennen.
    final step = kept.length / maxPoints;
    kept = [
      for (var i = 0; i < maxPoints - 1; i++) kept[(i * step).floor()],
      kept.last,
    ];
  }
  return kept;
}

/// Abstand des Punkts (px,py) vom Segment (ax,ay)-(bx,by).
double _segmentDistance(
    double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax;
  final dy = by - ay;
  final len2 = dx * dx + dy * dy;
  var t = len2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / len2;
  t = math.max(0.0, math.min(1.0, t));
  final cx = ax + t * dx;
  final cy = ay + t * dy;
  return math.sqrt((px - cx) * (px - cx) + (py - cy) * (py - cy));
}
