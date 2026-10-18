import 'dart:math' as math;

/// Bestimmt, wie weit voraus die Karte zeigt (Meter vom Fahrzeug bis zum
/// oberen Bildrand).
///
/// - Grundsatz: ca. [secondsAhead] Sekunden Fahrt voraus (schneller = weiter).
/// - Naht eine Abbiegung, wird herangezoomt, damit Abbiegung und ein Stueck
///   dahinter gut sichtbar sind.
/// - Aenderungen werden gedaempft, damit die Karte nicht springt.
class ZoomPolicy {
  const ZoomPolicy({
    this.minM = 120,
    this.maxM = 900,
    this.baseMinM = 200,
    this.secondsAhead = 15,
    this.maxStepFactor = 1.25,
  });

  /// Staerkste Vergroesserung (kleinste Sichtweite).
  final int minM;

  /// Staerkste Verkleinerung (groesste Sichtweite).
  final int maxM;

  /// Kleinste Sichtweite, solange keine Abbiegung naht.
  final int baseMinM;
  final double secondsAhead;

  /// Pro Aufruf (1 s) darf sich die Sichtweite hoechstens um diesen Faktor aendern.
  final double maxStepFactor;

  /// Ziel-Sichtweite ohne Daempfung.
  double target({required double speedKmh, required double distToTurnM}) {
    final speedMps = speedKmh.isFinite && speedKmh > 0 ? speedKmh / 3.6 : 0.0;
    final base = (speedMps * secondsAhead)
        .clamp(baseMinM.toDouble(), maxM.toDouble())
        .toDouble();
    final d = distToTurnM.isFinite ? math.max(0.0, distToTurnM) : double.infinity;
    if (d < base) {
      return (d * 1.5 + 80).clamp(minM.toDouble(), base).toDouble();
    }
    return base;
  }

  /// Gedaempfte, auf 10 m gerundete Sichtweite. [previous] = letzter Wert.
  int next({
    required int? previous,
    required double speedKmh,
    required double distToTurnM,
  }) {
    var z = target(speedKmh: speedKmh, distToTurnM: distToTurnM);
    if (previous != null) {
      z = z.clamp(previous / maxStepFactor, previous * maxStepFactor).toDouble();
    }
    return math.max(minM, math.min(maxM, (z / 10).round() * 10));
  }
}
