import 'dart:async';

import '../../core/models/gps_fix.dart';
import '../../core/models/nav_route.dart';
import '../../core/models/navigation_state.dart';
import '../encoder/esp32_encoder.dart';
import '../mapview/map_models.dart';
import '../mapview/map_window_builder.dart';
import '../mapview/roads/road_streamer.dart';
import 'output_channel.dart';

/// Sekundentakt: liest den neuesten Navigationszustand, kodiert ihn und
/// schickt ihn an den Kanal. Unabhaengig vom GPS-Rhythmus.
/// Ausserhalb einer laufenden Navigation wird nichts gesendet.
///
/// Mit [mapBuilder] und [readRoute] kommt die Kartenansicht dazu: ab und zu
/// ein Kartenstueck (Chunk), jede Sekunde die Pose als Zusatzfelder.
class OutputScheduler {
  OutputScheduler({
    required this.readState,
    required this.encoder,
    required this.channel,
    this.interval = const Duration(seconds: 1),
    this.onError,
    this.mapBuilder,
    this.readRoute,
    this.readFix,
    this.mapEnabled,
    this.roadStreamer,
    this.roadsEnabled,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final NavigationState Function() readState;
  final Esp32Encoder encoder;
  final OutputChannel channel;
  final Duration interval;
  final void Function(Object error)? onError;

  final MapWindowBuilder? mapBuilder;
  final NavRoute? Function()? readRoute;
  final GpsFix? Function()? readFix;

  /// Schalter fuer die Kartenansicht; null = immer an (sofern Builder da).
  final bool Function()? mapEnabled;
  final DateTime Function() _clock;

  /// Nebenstrassen (optional) und ihr Schalter; null = immer an.
  final RoadStreamer? roadStreamer;
  final bool Function()? roadsEnabled;
  bool _busy = false;

  Timer? _timer;

  void start() => _timer ??= Timer.periodic(interval, (_) => tick());

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Ein Sendevorgang (auch direkt aufrufbar, z. B. in Tests).
  Future<void> tick() async {
    // Dauert ein Takt laenger als eine Sekunde (viel zu senden), wird der
    // naechste uebersprungen statt sich zu ueberlappen.
    if (_busy) return;
    _busy = true;
    try {
      await _tick();
    } finally {
      _busy = false;
    }
  }

  Future<void> _tick() async {
    final state = readState();
    if (!state.active) {
      mapBuilder?.reset();
      roadStreamer?.reset();
      return;
    }

    MapUpdate? update;
    final builder = mapBuilder;
    final route = readRoute?.call();
    if (builder != null && route != null && (mapEnabled?.call() ?? true)) {
      try {
        update = builder.build(
          route: route,
          state: state,
          fix: readFix?.call(),
          now: _clock(),
        );
      } catch (e) {
        onError?.call(e);
      }
    } else {
      // Kartenansicht aus: beim Wiedereinschalten frisch beginnen.
      builder?.reset();
      roadStreamer?.reset();
    }

    final chunk = update?.chunk;
    if (chunk != null) {
      try {
        await channel.send(encoder.encodeMapChunk(chunk));
      } catch (e) {
        onError?.call(e);
      }
    }
    final streamer = roadStreamer;
    if (streamer != null && update != null) {
      try {
        final parts = streamer.next(
          update,
          now: _clock(),
          enabled: roadsEnabled?.call() ?? true,
        );
        for (final p in parts) {
          await channel.send(p);
        }
      } catch (e) {
        onError?.call(e);
      }
    }
    try {
      await channel.send(encoder.encode(state, pose: update?.pose));
    } catch (e) {
      onError?.call(e);
    }
  }
}
