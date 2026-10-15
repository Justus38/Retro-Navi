import 'output_channel.dart';

/// Ausgabe nur in die App: reicht die Nachricht an eine Senke (das
/// Debug-Log) weiter. Kennt weder Riverpod noch Flutter.
class DebugOutput implements OutputChannel {
  DebugOutput(this._sink);

  final void Function(String payload) _sink;

  @override
  Future<void> send(String payload) async => _sink(payload);
}
