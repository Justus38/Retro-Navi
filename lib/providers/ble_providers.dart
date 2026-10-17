import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ble/ble_models.dart';
import '../services/ble/ble_service.dart';

final bleServiceProvider = Provider<BleService>((ref) {
  final service = BleService();
  ref.onDispose(service.dispose);
  return service;
});

final bleLinkProvider = StreamProvider<BleLinkState>((ref) async* {
  final s = ref.watch(bleServiceProvider);
  yield s.state;
  yield* s.stateStream;
});

final bleScanResultsProvider = StreamProvider<List<BleDevice>>(
  (ref) => ref.watch(bleServiceProvider).scanResults,
);

final bleScanningProvider = StreamProvider<bool>(
  (ref) => ref.watch(bleServiceProvider).isScanning,
);

/// true = Bluetooth an. Beim ersten Start kurz null (unbekannt).
final bleAdapterOnProvider = StreamProvider<bool>(
  (ref) => ref.watch(bleServiceProvider).adapterOn,
);

/// Letzte Meldung fuer das Bluetooth-Panel (z. B. Scan-Fehler).
final bleMessageProvider = StateProvider<String?>((ref) => null);

final bleControllerProvider = Provider<BleController>((ref) => BleController(ref));

/// Beim App-Start mit dem zuletzt benutzten ESP32 verbinden (falls vorhanden).
final bleAutoConnectProvider = FutureProvider<void>(
  (ref) => ref.read(bleControllerProvider).autoConnect(),
);

class BleController {
  BleController(this._ref);

  final Ref _ref;
  static const _kId = 'ble.deviceId';
  static const _kName = 'ble.deviceName';

  BleService get _service => _ref.read(bleServiceProvider);
  void _say(String? m) => _ref.read(bleMessageProvider.notifier).state = m;

  Future<void> autoConnect() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final id = prefs.getString(_kId);
      if (id == null || id.isEmpty) return;
      unawaited(_service.connect(id, name: prefs.getString(_kName)));
    } catch (_) {
      // Gespeichertes Geraet nicht lesbar: einfach manuell verbinden.
    }
  }

  Future<void> scan() async {
    _say(null);
    try {
      await _service.startScan();
    } on BleException catch (e) {
      _say(e.message);
    }
  }

  Future<void> connect(BleDevice device) async {
    _say(null);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kId, device.id);
      await prefs.setString(_kName, device.name);
    } catch (_) {}
    unawaited(_service.connect(device.id, name: device.name));
  }

  /// Trennen, aber das Geraet fuer den naechsten App-Start merken.
  Future<void> disconnect() => _service.disconnect();

  /// Trennen und das gemerkte Geraet loeschen.
  Future<void> forget() async {
    await _service.disconnect();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kId);
      await prefs.remove(_kName);
    } catch (_) {}
  }
}
