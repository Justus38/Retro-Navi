/// Schmale Schnittstelle, die BleOutput braucht. Erleichtert Tests.
abstract interface class BleWriter {
  /// true, wenn gerade eine Verbindung steht und geschrieben werden kann.
  bool get isReady;

  Future<void> write(String payload);
}
