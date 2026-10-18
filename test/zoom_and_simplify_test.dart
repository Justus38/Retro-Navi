import 'package:flutter_test/flutter_test.dart';
import 'package:retro_navi/services/mapview/route_simplifier.dart';
import 'package:retro_navi/services/mapview/zoom_policy.dart';

void main() {
  group('ZoomPolicy', () {
    const z = ZoomPolicy();

    test('Stadttempo: Grundsichtweite 200 m, weit weg von der Abbiegung', () {
      expect(z.target(speedKmh: 30, distToTurnM: 5000), 200);
    });

    test('schneller = weiter voraus, aber hoechstens maxM', () {
      expect(z.target(speedKmh: 130, distToTurnM: 9999), closeTo(541, 1));
      expect(z.target(speedKmh: 300, distToTurnM: 9999), 900);
    });

    test('vor einer Abbiegung wird herangezoomt', () {
      // 50 km/h -> Grund 208 m; Abbiegung in 50 m -> 50*1.5+80 = 155 m
      expect(z.target(speedKmh: 50, distToTurnM: 50), closeTo(155, 0.5));
      // ganz nah: nie unter minM
      expect(z.target(speedKmh: 50, distToTurnM: 0), 120);
    });

    test('Daempfung: hoechstens +-25 % pro Schritt', () {
      expect(z.next(previous: 400, speedKmh: 50, distToTurnM: 0), 320);
      expect(z.next(previous: 200, speedKmh: 130, distToTurnM: 9999), 250);
      expect(z.next(previous: null, speedKmh: 50, distToTurnM: 9999), 210);
    });

    test('ungueltige Werte brechen nichts', () {
      expect(z.next(previous: null, speedKmh: double.nan, distToTurnM: double.nan), 200);
    });
  });

  group('Vereinfachung', () {
    test('Gerade: nur Anfang und Ende', () {
      final xs = [0.0, 0.0, 0.0, 0.0];
      final ys = [0.0, 10.0, 20.0, 30.0];
      expect(douglasPeucker(xs, ys, 2.5), [0, 3]);
    });

    test('Ecke bleibt erhalten', () {
      final xs = [0.0, 0.0, 0.0, 10.0, 20.0];
      final ys = [0.0, 10.0, 20.0, 20.0, 20.0];
      expect(douglasPeucker(xs, ys, 2.5), [0, 2, 4]);
    });

    test('kleine Abweichung unter der Toleranz wird geglaettet', () {
      final xs = [0.0, 1.0, 0.0, 1.0, 0.0];
      final ys = [0.0, 10.0, 20.0, 30.0, 40.0];
      expect(douglasPeucker(xs, ys, 2.5), [0, 4]);
    });

    test('simplifyToMax haelt die Obergrenze ein', () {
      final xs = [for (var i = 0; i < 200; i++) (i % 2 == 0 ? 0.0 : 6.0)];
      final ys = [for (var i = 0; i < 200; i++) i * 5.0];
      final kept = simplifyToMax(xs, ys, maxPoints: 30);
      expect(kept.length, lessThanOrEqualTo(30));
      expect(kept.first, 0);
      expect(kept.last, 199);
    });
  });
}
