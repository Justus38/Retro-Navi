import 'dart:async';

import '../../core/models/navigation_state.dart';
import '../encoder/esp32_encoder.dart';
import 'output_channel.dart';

/// Sekundentakt: liest den neuesten Navigationszustand, kodiert ihn und
/// schickt ihn an den Kanal. Unabhaengig vom GPS-Rhythmus.
/// Ausserhalb einer laufenden Navigation wird nichts gesendet.
class OutputScheduler {
  OutputScheduler({
    required this.readState,
    required this.encoder,
    required this.channel,
    this.interval = const Duration(seconds: 1),
    this.onError,
  });

  final NavigationState Function() readState;
  final Esp32Encoder encoder;
  final OutputChannel channel;
  final Duration interval;
  final void Function(Object error)? onError;

  Timer? _timer;

  void start() => _timer ??= Timer.periodic(interval, (_) => tick());

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Ein Sendevorgang (auch direkt aufrufbar, z. B. in Tests).
  Future<void> tick() async {
    final state = readState();
    if (!state.active) return;
    try {
      await channel.send(encoder.encode(state));
    } catch (e) {
      onError?.call(e);
    }
  }
}
