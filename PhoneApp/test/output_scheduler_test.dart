import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:retro_navi/core/models/nav_route.dart';
import 'package:retro_navi/core/models/navigation_state.dart';
import 'package:retro_navi/services/encoder/esp32_encoder.dart';
import 'package:retro_navi/services/mapview/map_window_builder.dart';
import 'package:retro_navi/services/mapview/roads/road_models.dart';
import 'package:retro_navi/services/mapview/roads/road_streamer.dart';
import 'package:retro_navi/services/output/output_channel.dart';
import 'package:retro_navi/services/output/output_scheduler.dart';

class _FakeChannel implements OutputChannel {
  final sent = <String>[];
  bool fail = false;

  @override
  Future<void> send(String payload) async {
    if (fail) throw StateError('kaputt');
    sent.add(payload);
  }
}

void main() {
  test('ohne laufende Navigation wird nichts gesendet', () async {
    final ch = _FakeChannel();
    final s = OutputScheduler(
      readState: () => const NavigationState(),
      encoder: const Esp32Encoder(),
      channel: ch,
    );
    await s.tick();
    expect(ch.sent, isEmpty);
  });

  test('bei laufender Navigation: ein JSON pro Tick', () async {
    final ch = _FakeChannel();
    final s = OutputScheduler(
      readState: () => const NavigationState(active: true, turn: TurnType.right),
      encoder: const Esp32Encoder(),
      channel: ch,
    );
    await s.tick();
    await s.tick();
    expect(ch.sent.length, 2);
    expect(ch.sent.first, contains('"turn":"R"'));
  });

  test('Fehler im Kanal werden gemeldet und werfen nicht', () async {
    final ch = _FakeChannel()..fail = true;
    final errors = <Object>[];
    final s = OutputScheduler(
      readState: () => const NavigationState(active: true),
      encoder: const Esp32Encoder(),
      channel: ch,
      onError: errors.add,
    );
    await s.tick();
    expect(errors.length, 1);
  });

  test('MultiOutput: ein defekter Kanal blockiert die anderen nicht', () async {
    final bad = _FakeChannel()..fail = true;
    final good = _FakeChannel();
    final multi = MultiOutput([bad, good]);
    await expectLater(multi.send('x'), throwsStateError);
    expect(good.sent, ['x']);
  });

  group('Kartenansicht', () {
    NavRoute route() => NavRoute(
          points: [for (var i = 0; i <= 9; i++) LatLng(48.0 + i * 0.001, 11.0)],
          steps: const [],
          distanceM: 1000,
          durationS: 100,
        );
    const state = NavigationState(
      active: true,
      turn: TurnType.right,
      distToTurnM: 300,
      remainingM: 800,
      speedKmh: 50,
    );

    OutputScheduler make(_FakeChannel ch, NavRoute r, {bool Function()? enabled}) {
      var now = DateTime(2026, 1, 1, 12);
      return OutputScheduler(
        readState: () => state,
        encoder: const Esp32Encoder(),
        channel: ch,
        mapBuilder: MapWindowBuilder(),
        readRoute: () => r,
        mapEnabled: enabled,
        clock: () => now = now.add(const Duration(seconds: 1)),
      );
    }

    test('erster Tick: Kartenstueck + Navigation mit Pose; danach nur Navigation', () async {
      final ch = _FakeChannel();
      final s = make(ch, route());
      await s.tick();
      expect(ch.sent.length, 2);
      final chunk = jsonDecode(ch.sent[0]) as Map<String, dynamic>;
      final nav = jsonDecode(ch.sent[1]) as Map<String, dynamic>;
      expect(chunk['t'], 'map');
      expect(nav['m'], chunk['id']);
      expect(nav.containsKey('x'), isTrue);

      await s.tick();
      expect(ch.sent.length, 3); // nur noch die Navigation
      expect(jsonDecode(ch.sent[2]).containsKey('t'), isFalse);
    });

    test('Kartenansicht aus: wie Phase 1, ohne Pose', () async {
      final ch = _FakeChannel();
      final s = make(ch, route(), enabled: () => false);
      await s.tick();
      expect(ch.sent.length, 1);
      expect(ch.sent.first, isNot(contains('"m":')));
    });

    test('ohne Route: nur Navigation', () async {
      final ch = _FakeChannel();
      final s = OutputScheduler(
        readState: () => state,
        encoder: const Esp32Encoder(),
        channel: ch,
        mapBuilder: MapWindowBuilder(),
        readRoute: () => null,
      );
      await s.tick();
      expect(ch.sent.length, 1);
    });

    test('ausserhalb der Navigation wird der Builder zurueckgesetzt (neuer Chunk)', () async {
      final ch = _FakeChannel();
      var active = true;
      final s = OutputScheduler(
        readState: () => active ? state : const NavigationState(),
        encoder: const Esp32Encoder(),
        channel: ch,
        mapBuilder: MapWindowBuilder(),
        readRoute: route,
      );
      await s.tick(); // Chunk + Nav
      active = false;
      await s.tick(); // nichts
      active = true;
      await s.tick(); // wieder Chunk + Nav
      expect(ch.sent.length, 4);
    });

    test('Nebenstrassen: erst Chunk + Nav, nach dem Laden eine rd-Nachricht vor der Nav', () async {
      final ch = _FakeChannel();
      final streamer = RoadStreamer(
        source: _EmptySource(),
        encoder: const Esp32Encoder(),
      );
      final s = OutputScheduler(
        readState: () => state,
        encoder: const Esp32Encoder(),
        channel: ch,
        mapBuilder: MapWindowBuilder(),
        readRoute: route,
        roadStreamer: streamer,
      );
      await s.tick();
      expect(ch.sent.length, 2); // Chunk + Nav, Strassen laden noch
      expect((jsonDecode(ch.sent[0]) as Map)['fr'], greaterThan(0));

      await pumpEventQueue();
      await s.tick();
      final types = [for (final m in ch.sent.skip(2)) (jsonDecode(m) as Map)['t']];
      expect(types, ['rd', null]); // Strassen vor der Navigation
    });

    test('Nebenstrassen aus: einmal loeschen', () async {
      final ch = _FakeChannel();
      var on = true;
      final s = OutputScheduler(
        readState: () => state,
        encoder: const Esp32Encoder(),
        channel: ch,
        mapBuilder: MapWindowBuilder(),
        readRoute: route,
        roadStreamer: RoadStreamer(source: _EmptySource(), encoder: const Esp32Encoder()),
        roadsEnabled: () => on,
      );
      await s.tick();
      await pumpEventQueue();
      await s.tick(); // rd (leer) + Nav
      on = false;
      final before = ch.sent.length;
      await s.tick(); // Loeschen + Nav
      final added = ch.sent.skip(before).map((m) => jsonDecode(m) as Map).toList();
      expect(added.first['t'], 'rd');
      expect(added.first['l'], isEmpty);
      await s.tick();
      expect(ch.sent.length, before + 3); // danach nur noch Nav
    });
  });
}

class _EmptySource implements RoadTileSource {
  @override
  Future<RoadTile?> tile(int z, int x, int y) async => null;
}
