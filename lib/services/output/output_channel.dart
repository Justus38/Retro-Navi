/// Ziel fuer die ESP32-Nachrichten. Aktuell DebugOutput, spaeter BleOutput.
/// Die Aufrufer kennen nur dieses Interface.
abstract interface class OutputChannel {
  /// Sendet eine fertig kodierte Nachricht (kompaktes JSON).
  Future<void> send(String payload);
}

/// Sendet an mehrere Kanaele gleichzeitig (z. B. Debug + BLE).
/// Faellt ein Kanal aus, bekommen die anderen die Nachricht trotzdem;
/// der erste Fehler wird danach weitergereicht.
class MultiOutput implements OutputChannel {
  MultiOutput(this.channels);

  final List<OutputChannel> channels;

  @override
  Future<void> send(String payload) async {
    Object? firstError;
    for (final channel in channels) {
      try {
        await channel.send(payload);
      } catch (e) {
        firstError ??= e;
      }
    }
    if (firstError != null) throw firstError;
  }
}
