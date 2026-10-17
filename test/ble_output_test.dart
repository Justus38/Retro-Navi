import 'package:flutter_test/flutter_test.dart';
import 'package:retro_navi/services/ble/ble_writer.dart';
import 'package:retro_navi/services/output/ble_output.dart';

class _FakeWriter implements BleWriter {
  @override
  bool isReady = false;
  bool fail = false;
  final written = <String>[];

  @override
  Future<void> write(String payload) async {
    if (fail) throw StateError('Schreibfehler');
    written.add(payload);
  }
}

void main() {
  test('ohne Verbindung wird nichts gesendet und nichts geworfen', () async {
    final w = _FakeWriter();
    await BleOutput(w).send('{"spd":1}');
    expect(w.written, isEmpty);
  });

  test('mit Verbindung wird die Nachricht durchgereicht', () async {
    final w = _FakeWriter()..isReady = true;
    await BleOutput(w).send('{"spd":1}');
    expect(w.written, ['{"spd":1}']);
  });

  test('Schreibfehler werden weitergereicht', () async {
    final w = _FakeWriter()
      ..isReady = true
      ..fail = true;
    await expectLater(BleOutput(w).send('x'), throwsStateError);
  });
}
