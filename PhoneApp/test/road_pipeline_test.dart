import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:retro_navi/services/encoder/esp32_encoder.dart';
import 'package:retro_navi/services/mapview/local_frame.dart';
import 'package:retro_navi/services/mapview/map_models.dart';
import 'package:retro_navi/services/mapview/roads/mvt_decoder.dart';
import 'package:retro_navi/services/mapview/roads/openfreemap_source.dart';
import 'package:retro_navi/services/mapview/roads/road_extractor.dart';
import 'package:retro_navi/services/mapview/roads/road_models.dart';
import 'package:retro_navi/services/mapview/roads/road_streamer.dart';
import 'package:retro_navi/services/mapview/roads/tile_math.dart';

import 'support/mvt_fixture.dart';

// Kachel 14/8700/5700; ihre Mitte ist der Ursprung des lokalen Systems.
const _z = 14, _tx = 8700, _ty = 5700;
final _origin = LatLng(tileLat(_ty, 2048, 4096, _z), tileLon(_tx, 2048, 4096, _z));
final _frame = LocalFrame(_origin);
final _mpuX = _frame.x(LatLng(_origin.latitude, tileLon(_tx, 3048, 4096, _z))) / 1000;
final _mpuY = _frame.y(LatLng(tileLat(_ty, 1048, 4096, _z), _origin.longitude)) / 1000;

/// Meter im lokalen System -> Kachelkoordinaten.
int _ux(double x) => (2048 + x / _mpuX).round();
int _uy(double y) => (2048 - y / _mpuY).round();
List<int> _line(List<List<double>> pts) => [
      for (final p in pts) ...[_ux(p[0]), _uy(p[1])]
    ];

Uint8List _testTile() => buildTile([
      // Nebenstrasse: beginnt auf der Route, 400 m nach Osten (nur 2 Punkte!)
      FixtureFeature('minor', [_line([[0, 100], [400, 100]])]),
      // Hauptstrasse quert die Route
      FixtureFeature('primary', [_line([[-300, -100], [300, -100]])]),
      // wird nicht gezeichnet
      FixtureFeature('service', [_line([[50, 0], [200, 0]])]),
      // zu weit weg
      FixtureFeature('minor', [_line([[700, 0], [700, 100]])]),
      // liegt auf der Route selbst
      FixtureFeature('minor', [_line([[0, -250], [0, 250]])]),
      // Polygon: ignorieren
      FixtureFeature('minor', [_line([[10, 10], [60, 10], [60, 60]])], type: 3),
    ]);

void main() {
  group('Kachel-Decoder', () {
    test('liest Linien mit Klasse, ueberspringt andere Ebenen und Polygone', () {
      final bytes = buildTile([
        FixtureFeature('minor', [
          [10, 20, 110, 20, 110, 120]
        ]),
        FixtureFeature('primary', [
          [0, 0, 50, 0],
          [-30, 400, -30, 500, 20, 500], // Cursor laeuft ueber Linien weiter
        ]),
        FixtureFeature('minor', [
          [1, 1, 2, 2, 3, 1]
        ], type: 3),
      ]);
      final layer = decodeMvtLines(bytes, 'transportation')!;
      expect(layer.extent, 4096);
      expect(layer.lines.map((l) => l.roadClass), ['minor', 'primary', 'primary']);
      expect(layer.lines[0].coords, [10, 20, 110, 20, 110, 120]);
      expect(layer.lines[1].coords, [0, 0, 50, 0]);
      expect(layer.lines[2].coords, [-30, 400, -30, 500, 20, 500]);
    });

    test('fehlende Ebene -> null, kaputte Daten -> FormatException', () {
      final bytes = buildTile([
        FixtureFeature('minor', [
          [0, 0, 5, 5]
        ])
      ]);
      expect(decodeMvtLines(bytes, 'gibt_es_nicht'), isNull);
      expect(decodeMvtLines(Uint8List(0), 'transportation'), isNull);
      expect(() => decodeMvtLines(Uint8List.fromList([0x1a, 0x7f, 1, 2]), 'transportation'),
          throwsFormatException);
    });
  });

  group('Strassen auswaehlen', () {
    final layer = decodeMvtLines(_testTile(), 'transportation')!;
    final tile = RoadTile(_z, _tx, _ty, layer);
    const extractor = RoadExtractor();
    final runs = extractor.extract(
      tiles: [tile],
      frame: _frame,
      routeXs: const [0, 0],
      routeYs: const [-300, 300],
      vehicleX: 0,
      vehicleY: 0,
    );

    test('Hauptstrasse zuerst, dann die Seitenstrasse; Strasse auf der Route entfaellt', () {
      expect(runs.map((r) => r.cls), [2, 1]);
    });

    test('Querende Hauptstrasse laeuft ohne Luecke ueber die Route', () {
      final main = runs.first;
      // ein einziger Linienzug von weit links bis weit rechts, y ca. -100
      expect(main.pts.first, lessThan(-200));
      expect(main.pts[main.pts.length - 2], greaterThan(200));
      expect(main.pts[1], closeTo(-100, 3));
      expect(main.pointCount, 2); // gerade Linie
    });

    test('Nebenstrasse beginnt direkt an der Route (keine Luecke) und endet am Korridorrand', () {
      final side = runs.last;
      expect(side.cls, 1);
      expect(side.pts.first, inInclusiveRange(-3, 3)); // Anschluss an die Route
      expect(side.pts[1], closeTo(100, 3));
      expect(side.pts[side.pts.length - 2], greaterThan(200));
      expect(side.pts[side.pts.length - 2], lessThanOrEqualTo(265));
    });

    test('Strasse, die nur ein Stueck auf der Route liegt, bleibt mit einem Anschlusspunkt', () {
      // Beginnt auf der Route (y 0..60 liegt auf ihr), biegt dann nach Osten ab.
      final t = RoadTile(
          _z,
          _tx,
          _ty,
          decodeMvtLines(
              buildTile([
                FixtureFeature('minor', [
                  _line([[0, -60], [0, 60], [200, 60]])
                ])
              ]),
              'transportation')!);
      final out = const RoadExtractor().extract(
        tiles: [t],
        frame: _frame,
        routeXs: const [0, 0],
        routeYs: const [-300, 300],
        vehicleX: 0,
        vehicleY: 0,
      );
      expect(out.length, 1);
      // Anfang ist der Anschluss an der Route, nicht erst 30 m weiter
      expect(out.single.pts.first, inInclusiveRange(-3, 3));
      expect(out.single.pts[1], closeTo(60, 40));
    });

    test('Punktgrenze: Hauptstrassen bleiben, Rest wird abgeschnitten', () {
      final few = const RoadExtractor(maxPoints: 2).extract(
        tiles: [tile],
        frame: _frame,
        routeXs: const [0, 0],
        routeYs: const [-300, 300],
        vehicleX: 0,
        vehicleY: 0,
      );
      expect(few.every((r) => r.cls == 2), isTrue);
      expect(few.fold<int>(0, (a, r) => a + r.pointCount), lessThanOrEqualTo(2));
    });

    test('lange Linien werden in Stuecke zu hoechstens maxRunPoints geteilt', () {
      // Zickzack-Strasse (viele Ecken), 250 m seitlich der Route.
      final pts = <List<double>>[
        for (var i = 0; i < 40; i++) [60.0 + (i % 2) * 20, -280.0 + i * 14]
      ];
      final t = RoadTile(
          _z,
          _tx,
          _ty,
          decodeMvtLines(
              buildTile([FixtureFeature('minor', [_line(pts)])]), 'transportation')!);
      final out = const RoadExtractor(maxRunPoints: 10, simplifyM: 1).extract(
        tiles: [t],
        frame: _frame,
        routeXs: const [0, 0],
        routeYs: const [-300, 300],
        vehicleX: 0,
        vehicleY: 0,
      );
      expect(out.length, greaterThan(1));
      expect(out.every((r) => r.pointCount <= 10), isTrue);
    });
  });

  group('Nachrichten', () {
    const enc = Esp32Encoder();

    test('Delta-Kodierung und Teile', () {
      final parts = enc.encodeRoadParts(
        const [
          RoadRun(1, [10, 20, 15, 18, 15, 30]),
          RoadRun(2, [-5, -6, 0, 0]),
        ],
        frameId: 3,
        generation: 7,
      );
      expect(parts, [
        '{"t":"rd","fr":3,"g":7,"n":0,"f":1,"l":[[1,10,20,5,-2,0,12],[2,-5,-6,5,6]]}'
      ]);
    });

    test('mehrere Teile: laufende Nummer, nur der letzte hat f=1, jeder kurz genug', () {
      final runs = [
        for (var i = 0; i < 30; i++)
          RoadRun(1, [i * 10, 0, i * 10 + 50, 30, i * 10 + 90, 20, i * 10 + 120, 60]),
      ];
      final parts = enc.encodeRoadParts(runs, frameId: 1, generation: 2, maxChars: 300);
      expect(parts.length, greaterThan(3));
      var total = 0;
      for (var i = 0; i < parts.length; i++) {
        final m = jsonDecode(parts[i]) as Map<String, dynamic>;
        expect(m['n'], i);
        expect(m['f'], i == parts.length - 1 ? 1 : 0);
        expect(parts[i].length, lessThan(400));
        total += (m['l'] as List).length;
      }
      expect(total, 30);
    });

    test('leere Liste = eine Nachricht, die alles loescht', () {
      final parts = enc.encodeRoadParts(const [], frameId: 4, generation: 9);
      expect(parts, ['{"t":"rd","fr":4,"g":9,"n":0,"f":1,"l":[]}']);
    });

    test('Kartenstueck mit Koordinatensystem', () {
      const c = MapChunk(id: 3, route: [0, 0, 5, 5], routeEnd: false, frameId: 2);
      expect(enc.encodeMapChunk(c), '{"t":"map","id":3,"fr":2,"e":0,"r":[0,0,5,5]}');
    });
  });

  group('OpenFreeMap-Quelle', () {
    test('TileJSON, Kachel-URL, Cache, gzip', () async {
      final tileBytes = _testTile();
      final requests = <Uri>[];
      final headers = <Map<String, String>>[];
      final client = MockClient((req) async {
        requests.add(req.url);
        headers.add(req.headers);
        if (req.url.path == '/planet') {
          return http.Response(
              jsonEncode({
                'tiles': ['https://tiles.example/planet/20260101_pt/{z}/{x}/{y}.pbf']
              }),
              200);
        }
        return http.Response.bytes(gzip.encode(tileBytes), 200);
      });
      final src = OpenFreeMapTileSource(client, 'RetroNavi/test',
          tileJsonUrl: 'https://tiles.example/planet');

      final t = await src.tile(14, 8700, 5700);
      expect(t, isNotNull);
      expect(t!.layer.lines, isNotEmpty);
      expect(requests.map((u) => u.toString()), [
        'https://tiles.example/planet',
        'https://tiles.example/planet/20260101_pt/14/8700/5700.pbf',
      ]);
      expect(headers.every((h) => h['User-Agent'] == 'RetroNavi/test'), isTrue);

      await src.tile(14, 8700, 5700); // aus dem Cache
      expect(requests.length, 2);
    });

    test('404 / 204 = leere Kachel, anderer Fehler wird gemeldet', () async {
      var status = 404;
      final client = MockClient((req) async {
        if (req.url.path == '/planet') {
          return http.Response(
              jsonEncode({
                'tiles': ['https://tiles.example/v/{z}/{x}/{y}.pbf']
              }),
              200);
        }
        return http.Response('', status);
      });
      final src = OpenFreeMapTileSource(client, 'x', tileJsonUrl: 'https://tiles.example/planet');
      expect(await src.tile(14, 1, 1), isNull);
      status = 500;
      await expectLater(src.tile(14, 2, 2), throwsA(isA<http.ClientException>()));
    });
  });

  group('RoadStreamer', () {
    final tileBytes = _testTile();

    MapUpdate update({int frameId = 3, int chunkId = 1, double along = 300}) => MapUpdate(
          pose: const MapPose(
              chunkId: 1, x: 0, y: 0, headingDeg: 0, zoomM: 200, nextIndex: 1),
          window: MapWindow(
            frame: _frame,
            frameId: frameId,
            chunkId: chunkId,
            xs: const [0, 0],
            ys: const [-300, 300],
            alongs: const [0, 600],
            vehicleAlong: along,
          ),
        );

    RoadStreamer make(RoadTileSource src, {void Function(Object)? onError}) => RoadStreamer(
          source: src,
          encoder: const Esp32Encoder(),
          onError: onError,
          partsPerTick: 1,
        );

    final t0 = DateTime(2026, 1, 1, 12);

    test('laedt im Hintergrund, liefert dann Teile; letzter Teil hat f=1', () async {
      final layer = decodeMvtLines(tileBytes, 'transportation')!;
      final src = _FakeSource(RoadTile(_z, _tx, _ty, layer));
      final s = make(src);

      expect(s.next(update(), now: t0), isEmpty); // Laden beginnt
      await pumpEventQueue();

      final msgs = <Map<String, dynamic>>[];
      for (var i = 1; i < 10; i++) {
        for (final m in s.next(update(), now: t0.add(Duration(seconds: i)))) {
          msgs.add(jsonDecode(m) as Map<String, dynamic>);
        }
      }
      expect(msgs, isNotEmpty);
      expect(msgs.first['t'], 'rd');
      expect(msgs.first['fr'], 3);
      expect(msgs.first['n'], 0);
      expect(msgs.last['f'], 1);
      expect(src.requested, [(14, _tx, _ty)]);
    });

    test('nach 40 s ohne Neues wird die Ausgabe wiederholt', () async {
      final layer = decodeMvtLines(tileBytes, 'transportation')!;
      final s = make(_FakeSource(RoadTile(_z, _tx, _ty, layer)));
      s.next(update(), now: t0);
      await pumpEventQueue();
      final first = s.next(update(), now: t0.add(const Duration(seconds: 1)));
      expect(first, isNotEmpty);
      expect(s.next(update(), now: t0.add(const Duration(seconds: 2))), isEmpty);
      final again = s.next(update(), now: t0.add(const Duration(seconds: 45)));
      expect(again, first);
    });

    test('Schalter aus: einmal loeschen, danach Ruhe', () async {
      final layer = decodeMvtLines(tileBytes, 'transportation')!;
      final s = make(_FakeSource(RoadTile(_z, _tx, _ty, layer)));
      s.next(update(), now: t0);
      await pumpEventQueue();
      expect(s.next(update(), now: t0.add(const Duration(seconds: 1))), isNotEmpty);

      final off = s.next(update(), now: t0.add(const Duration(seconds: 2)), enabled: false);
      expect(off.length, 1);
      final m = jsonDecode(off.single) as Map<String, dynamic>;
      expect(m['l'], isEmpty);
      expect(m['f'], 1);
      expect(s.next(update(), now: t0.add(const Duration(seconds: 3)), enabled: false), isEmpty);
    });

    test('Fehler beim Laden: gemeldet, nach retryAfter neuer Versuch', () async {
      final errors = <Object>[];
      final src = _FakeSource(null, fail: true);
      final s = make(src, onError: errors.add);
      s.next(update(), now: t0);
      await pumpEventQueue();
      expect(errors.length, 1);
      s.next(update(), now: t0.add(const Duration(seconds: 5))); // zu frueh
      await pumpEventQueue();
      expect(errors.length, 1);
      s.next(update(), now: t0.add(const Duration(seconds: 20)));
      await pumpEventQueue();
      expect(errors.length, 2);
    });

    test('neues Koordinatensystem: alte Teile verfallen, neu laden', () async {
      final layer = decodeMvtLines(tileBytes, 'transportation')!;
      final src = _FakeSource(RoadTile(_z, _tx, _ty, layer));
      final s = make(src);
      s.next(update(), now: t0);
      await pumpEventQueue();
      s.next(update(frameId: 4), now: t0.add(const Duration(seconds: 1)));
      await pumpEventQueue();
      final m = s.next(update(frameId: 4), now: t0.add(const Duration(seconds: 2)));
      expect(m, isNotEmpty);
      expect((jsonDecode(m.first) as Map<String, dynamic>)['fr'], 4);
    });
  });
}

class _FakeSource implements RoadTileSource {
  _FakeSource(this.tile_, {this.fail = false});

  final RoadTile? tile_;
  final bool fail;
  final requested = <(int, int, int)>[];

  @override
  Future<RoadTile?> tile(int z, int x, int y) async {
    requested.add((z, x, y));
    if (fail) throw StateError('kein Netz');
    return (z == _z && x == _tx && y == _ty) ? tile_ : null;
  }
}
