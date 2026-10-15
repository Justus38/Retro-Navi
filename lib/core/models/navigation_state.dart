import 'nav_route.dart';

/// Ergebnis der NavigationEngine fuer einen GPS-Fix.
/// Wird jede Sekunde neu erzeugt und spaeter vom Esp32Encoder ausgewertet.
class NavigationState {
  const NavigationState({
    this.active = false,
    this.turn = TurnType.straight,
    this.instruction = '',
    this.distToTurnM = 0,
    this.street = '',
    this.exitNumber,
    this.remainingM = 0,
    this.remainingS = 0,
    this.speedKmh = 0,
    this.stepIndex = 0,
    this.offRouteM = 0,
    this.offRoute = false,
    this.arrived = false,
    this.rerouting = false,
    this.error,
  });

  final bool active;

  /// Art des NAECHSTEN Manoevers.
  final TurnType turn;
  final String instruction;

  /// Distanz bis zu diesem Manoever in Metern.
  final double distToTurnM;

  /// Strasse, auf die abgebogen wird (sonst die aktuelle Strasse).
  final String street;

  /// Ausfahrt im Kreisverkehr (nur wenn von ORS geliefert).
  final int? exitNumber;

  final double remainingM;
  final double remainingS;
  final double speedKmh;

  /// Index des naechsten Manoevers in [NavRoute.steps].
  final int stepIndex;

  /// Abstand zur Route in Metern.
  final double offRouteM;
  final bool offRoute;
  final bool arrived;
  final bool rerouting;
  final String? error;

  NavigationState copyWith({
    bool? active,
    bool? rerouting,
    String? error,
    bool clearError = false,
  }) =>
      NavigationState(
        active: active ?? this.active,
        turn: turn,
        instruction: instruction,
        distToTurnM: distToTurnM,
        street: street,
        exitNumber: exitNumber,
        remainingM: remainingM,
        remainingS: remainingS,
        speedKmh: speedKmh,
        stepIndex: stepIndex,
        offRouteM: offRouteM,
        offRoute: offRoute,
        arrived: arrived,
        rerouting: rerouting ?? this.rerouting,
        error: clearError ? null : (error ?? this.error),
      );
}
