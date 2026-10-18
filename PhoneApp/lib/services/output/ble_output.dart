import '../ble/ble_writer.dart';
import 'output_channel.dart';

/// Schickt die ESP32-Nachrichten per Bluetooth. Ist gerade keine Verbindung
/// da, passiert nichts (das ist ein normaler Zustand, kein Fehler).
class BleOutput implements OutputChannel {
  BleOutput(this._writer);

  final BleWriter _writer;

  @override
  Future<void> send(String payload) async {
    if (!_writer.isReady) return;
    await _writer.write(payload);
  }
}
