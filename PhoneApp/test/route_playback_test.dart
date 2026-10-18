import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:retro_navi/core/geo.dart';
import 'package:retro_navi/services/simulation/route_playback.dart';

List<LatLng> _north() => [for (var i = 0; i <= 10; i++) LatLng(48.0 + i * 0.001, 11.0)];

void main() {
  test('Position und Kurs nach 250 m auf einer Nord-Geraden', () {
    final pb = RoutePlayback(_north())..advance(250);
    expect(pb.position.latitude, closeTo(48.0 + 250 / 111194.93, 1e-6));
    expect(pb.position.longitude, closeTo(11.0, 1e-9));
    expect(pb.heading, closeTo(0, 0.5));
    expect(pb.finished, isFalse);
  });

  test('Streckenende: bleibt am letzten Punkt und gilt als beendet', () {
    final pb = RoutePlayback(_north())..advance(100000);
    expect(pb.finished, isTrue);
    expect(pb.position.latitude, closeTo(48.01, 1e-9));
  });

  test('Ost-Gerade hat Kurs ~90 Grad', () {
    final pts = [for (var i = 0; i <= 5; i++) LatLng(48.0, 11.0 + i * 0.001)];
    final pb = RoutePlayback(pts)..advance(100);
    expect(pb.heading, closeTo(90, 0.2));
  });

  test('doppelte Punkte lassen den Kurs nicht springen', () {
    final pts = [
      const LatLng(48.0, 11.0),
      const LatLng(48.001, 11.0),
      const LatLng(48.001, 11.0), // Duplikat
      const LatLng(48.002, 11.0),
    ];
    final pb = RoutePlayback(pts)..advance(111.2); // genau am Duplikat
    expect(pb.heading, closeTo(0, 0.5));
  });

  test('reset setzt auf den Anfang zurueck', () {
    final pb = RoutePlayback(_north())
      ..advance(500)
      ..reset();
    expect(pb.progressM, 0);
    expect(pb.position.latitude, closeTo(48.0, 1e-9));
  });

  test('offsetPoint: 100 m nach Osten', () {
    const a = LatLng(48.0, 11.0);
    final b = offsetPoint(a, 90, 100);
    expect(haversineM(a, b), closeTo(100, 0.5));
    expect(b.latitude, closeTo(48.0, 1e-6));
    expect(b.longitude, greaterThan(11.0));
  });
}
