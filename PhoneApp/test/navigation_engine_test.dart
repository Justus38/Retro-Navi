import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:retro_navi/core/models/gps_fix.dart';
import 'package:retro_navi/core/models/nav_route.dart';
import 'package:retro_navi/services/navigation/navigation_engine.dart';

/// Gerade Route nach Norden: 11 Punkte, je 0.001 Grad (~111,19 m) Abstand.
/// Schritt 0: Start (Punkt 0-5), Schritt 1: links abbiegen (5-10), Schritt 2: Ziel.
NavRoute _route() => NavRoute(
      points: [for (var i = 0; i <= 10; i++) LatLng(48.0 + i * 0.001, 11.0)],
      distanceM: 1111.9,
      durationS: 120,
      steps: const [
        RouteStep(
            type: TurnType.depart,
            instruction: 'Start',
            streetName: 'Startstr',
            distanceM: 556,
            durationS: 60,
            startIndex: 0,
            endIndex: 5),
        RouteStep(
            type: TurnType.left,
            instruction: 'Links abbiegen',
            streetName: 'Hauptstr',
            distanceM: 556,
            durationS: 60,
            startIndex: 5,
            endIndex: 10),
        RouteStep(
            type: TurnType.goal,
            instruction: 'Ziel erreicht',
            streetName: '',
            distanceM: 0,
            durationS: 0,
            startIndex: 10,
            endIndex: 10),
      ],
    );

GpsFix _fix(double lat, double lon, {double speedMps = 10, double acc = 5}) => GpsFix(
      lat: lat,
      lng: lon,
      speedMps: speedMps,
      heading: 0,
      accuracy: acc,
      timestamp: DateTime(2026),
    );

void main() {
  const mPerStep = 111.195;

  test('am Start: naechstes Manoever ist Links nach 5 Segmenten', () {
    final s = NavigationEngine(_route()).update(_fix(48.0, 11.0));
    expect(s.turn, TurnType.left);
    expect(s.street, 'Hauptstr');
    expect(s.distToTurnM, closeTo(5 * mPerStep, 3));
    expect(s.remainingM, closeTo(10 * mPerStep, 3));
    expect(s.remainingS, closeTo(120, 1));
    expect(s.speedKmh, closeTo(36, 0.01));
    expect(s.offRoute, isFalse);
  });

  test('seitlicher Versatz von ~11 m gilt noch als auf der Route', () {
    final s = NavigationEngine(_route()).update(_fix(48.003, 11.00015));
    expect(s.offRoute, isFalse);
    expect(s.distToTurnM, closeTo(2 * mPerStep, 3));
  });

  test('nach dem Abbiegepunkt ist das Ziel das naechste Manoever', () {
    final s = NavigationEngine(_route()).update(_fix(48.006, 11.0));
    expect(s.turn, TurnType.goal);
    expect(s.distToTurnM, closeTo(4 * mPerStep, 3));
  });

  test('Abweichung wird erst nach 2 Fixes in Folge gemeldet', () {
    final engine = NavigationEngine(_route());
    engine.update(_fix(48.002, 11.0));
    final first = engine.update(_fix(48.002, 11.0027)); // ~200 m ostwaerts
    final second = engine.update(_fix(48.002, 11.0027));
    expect(first.offRoute, isFalse);
    expect(second.offRoute, isTrue);
    expect(second.offRouteM, greaterThan(150));
  });

  test('Rueckkehr auf die Route setzt die Abweichung zurueck', () {
    final engine = NavigationEngine(_route());
    engine.update(_fix(48.002, 11.0027));
    engine.update(_fix(48.002, 11.0027));
    final back = engine.update(_fix(48.003, 11.0));
    expect(back.offRoute, isFalse);
  });

  test('am Zielpunkt: angekommen', () {
    final s = NavigationEngine(_route()).update(_fix(48.01, 11.0));
    expect(s.arrived, isTrue);
    expect(s.turn, TurnType.goal);
    expect(s.remainingM, lessThan(1));
    expect(s.remainingS, 0);
  });
}
