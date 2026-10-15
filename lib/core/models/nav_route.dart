import 'package:latlong2/latlong.dart';

/// Abbiegeart (Reihenfolge entspricht den ORS-Typcodes 0-13).
enum TurnType {
  left,
  right,
  sharpLeft,
  sharpRight,
  slightLeft,
  slightRight,
  straight,
  enterRoundabout,
  exitRoundabout,
  uTurn,
  goal,
  depart,
  keepLeft,
  keepRight;

  static TurnType fromOrs(int code) =>
      (code >= 0 && code < values.length) ? values[code] : TurnType.straight;
}

/// Ein Manoever der Route. [startIndex]/[endIndex] zeigen in [NavRoute.points].
/// Das Manoever selbst passiert am Punkt [startIndex]; die Strecke bis zum
/// naechsten Manoever liegt zwischen startIndex und endIndex.
class RouteStep {
  const RouteStep({
    required this.type,
    required this.instruction,
    required this.streetName,
    required this.distanceM,
    required this.durationS,
    required this.startIndex,
    required this.endIndex,
    this.exitNumber,
  });

  final TurnType type;
  final String instruction;

  /// Strassenname nach dem Manoever, leer wenn unbekannt.
  final String streetName;
  final double distanceM;
  final double durationS;
  final int startIndex;
  final int endIndex;

  /// Ausfahrt im Kreisverkehr (falls von ORS geliefert).
  final int? exitNumber;
}

class NavRoute {
  const NavRoute({
    required this.points,
    required this.steps,
    required this.distanceM,
    required this.durationS,
  });

  final List<LatLng> points;
  final List<RouteStep> steps;
  final double distanceM;
  final double durationS;
}
