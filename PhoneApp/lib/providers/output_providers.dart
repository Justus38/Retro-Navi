import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/encoder/esp32_encoder.dart';
import '../services/mapview/map_window_builder.dart';
import '../services/mapview/roads/openfreemap_source.dart';
import '../services/mapview/roads/road_streamer.dart';
import '../services/output/ble_output.dart';
import '../services/output/debug_output.dart';
import '../services/output/output_channel.dart';
import '../services/output/output_scheduler.dart';
import '../core/config/app_config.dart';
import 'ble_providers.dart';
import 'geocoding_providers.dart';
import 'navigation_providers.dart';
import 'position_providers.dart';
import 'routing_providers.dart';

// ---------------------------------------------------------------- Debug-Log

class DebugEntry {
  const DebugEntry(this.time, this.text, {this.isError = false});
  final DateTime time;
  final String text;
  final bool isError;
}

class DebugLogState {
  const DebugLogState({this.entries = const [], this.sentCount = 0, this.lastPayload});

  /// Neueste zuerst.
  final List<DebugEntry> entries;
  final int sentCount;
  final String? lastPayload;
}

class DebugLogController extends Notifier<DebugLogState> {
  static const maxEntries = 100;

  @override
  DebugLogState build() => const DebugLogState();

  void add(String payload) {
    // Kartenstuecke sind ~1 kB lang; im Verlauf nur der Anfang.
    final shown = payload.length > 140
        ? '${payload.substring(0, 140)} ... (${payload.length} Zeichen)'
        : payload;
    state = DebugLogState(
      entries: [DebugEntry(DateTime.now(), shown), ...state.entries]
          .take(maxEntries)
          .toList(),
      sentCount: state.sentCount + 1,
      lastPayload: payload,
    );
  }

  void addError(String message) {
    state = DebugLogState(
      entries: [DebugEntry(DateTime.now(), message, isError: true), ...state.entries]
          .take(maxEntries)
          .toList(),
      sentCount: state.sentCount,
      lastPayload: state.lastPayload,
    );
  }

  void clear() => state = const DebugLogState();
}

final debugLogProvider =
    NotifierProvider<DebugLogController, DebugLogState>(DebugLogController.new);

// ------------------------------------------------------------- Ausgabekette

final esp32EncoderProvider = Provider<Esp32Encoder>((ref) => const Esp32Encoder());

/// DER Ausgabekanal der App: Debug-Log und Bluetooth parallel.
final outputChannelProvider = Provider<OutputChannel>((ref) {
  final debug = DebugOutput(ref.read(debugLogProvider.notifier).add);
  final ble = BleOutput(ref.watch(bleServiceProvider));
  return MultiOutput([debug, ble]);
});

/// Schalter: Kartenansicht (Route, Fahrzeug) statt nur Abbiegepfeil auf dem
/// ESP32-Display. Setzt den neuen Sketch voraus.
final mapViewEnabledProvider = StateProvider<bool>((ref) => true);

final mapWindowBuilderProvider = Provider<MapWindowBuilder>((ref) => MapWindowBuilder());

/// Schalter: Nebenstrassen (aus Vektorkacheln) unter der Route zeichnen.
/// Braucht Internet und den neuen ESP32-Sketch.
final sideRoadsEnabledProvider = StateProvider<bool>((ref) => true);

final roadStreamerProvider = Provider<RoadStreamer>((ref) {
  final config = ref.watch(appConfigProvider);
  return RoadStreamer(
    source: OpenFreeMapTileSource(ref.watch(httpClientProvider), config.userAgent),
    encoder: ref.watch(esp32EncoderProvider),
    onError: (e) =>
        ref.read(debugLogProvider.notifier).addError('Nebenstrassen laden fehlgeschlagen: $e'),
  );
});

/// Sekundentakt. Muss irgendwo beobachtet werden (MapScreen), damit er laeuft.
final outputSchedulerProvider = Provider<OutputScheduler>((ref) {
  final scheduler = OutputScheduler(
    readState: () => ref.read(navigationProvider),
    encoder: ref.watch(esp32EncoderProvider),
    channel: ref.watch(outputChannelProvider),
    onError: (e) => ref.read(debugLogProvider.notifier).addError('Senden fehlgeschlagen: $e'),
    mapBuilder: ref.watch(mapWindowBuilderProvider),
    readRoute: () => ref.read(routeProvider).valueOrNull,
    readFix: () => ref.read(positionStreamProvider).valueOrNull,
    mapEnabled: () => ref.read(mapViewEnabledProvider),
    roadStreamer: ref.watch(roadStreamerProvider),
    roadsEnabled: () => ref.read(sideRoadsEnabledProvider),
  )..start();
  ref.onDispose(scheduler.stop);
  return scheduler;
});
