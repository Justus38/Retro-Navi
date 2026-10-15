import 'package:flutter_test/flutter_test.dart';
import 'package:retro_navi/core/models/nav_route.dart';
import 'package:retro_navi/core/models/navigation_state.dart';
import 'package:retro_navi/services/encoder/esp32_encoder.dart';
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
}
