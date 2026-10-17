import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_chunker.dart';
import 'ble_constants.dart';
import 'ble_models.dart';
import 'ble_writer.dart';

/// Einzige Stelle der App, die flutter_blue_plus kennt.
/// Scannen, Verbinden (mit automatischem Wiederverbinden) und Schreiben.
class BleService implements BleWriter {
  final _stateCtrl = StreamController<BleLinkState>.broadcast();
  BleLinkState _state = const BleLinkState();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  String? _wantedId;
  String? _wantedName;

  /// Jede neue Verbindungsanfrage oder Trennung erhoeht den Zaehler und
  /// macht damit alle laufenden Versuche der alten Sitzung ungueltig.
  int _session = 0;
  bool _writing = false;
  bool _disposed = false;

  BleLinkState get state => _state;
  Stream<BleLinkState> get stateStream => _stateCtrl.stream;

  @override
  bool get isReady => _state.status == BleStatus.connected && _rx != null;

  // ------------------------------------------------------------------ Scan

  Stream<List<BleDevice>> get scanResults =>
      FlutterBluePlus.scanResults.map(_mapResults);

  Stream<bool> get isScanning => FlutterBluePlus.isScanning;

  Stream<bool> get adapterOn => FlutterBluePlus.adapterState
      .map((s) => s == BluetoothAdapterState.on);

  Future<void> startScan() async {
    if (FlutterBluePlus.isScanningNow) return;
    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    } catch (e) {
      throw BleException('Scan fehlgeschlagen: ${_short(e)}');
    }
  }

  Future<void> stopScan() async {
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  List<BleDevice> _mapResults(List<ScanResult> list) {
    final ours = Guid(kBleServiceUuid);
    final devices = <BleDevice>[];
    for (final r in list) {
      final adv = r.advertisementData.advName;
      final name = adv.isNotEmpty ? adv : r.device.platformName;
      devices.add(BleDevice(
        id: r.device.remoteId.str,
        name: name,
        rssi: r.rssi,
        isRetroNavi: r.advertisementData.serviceUuids.contains(ours) ||
            name.startsWith(kBleNamePrefix),
      ));
    }
    devices.sort((a, b) {
      if (a.isRetroNavi != b.isRetroNavi) return a.isRetroNavi ? -1 : 1;
      return b.rssi.compareTo(a.rssi);
    });
    return devices;
  }

  // -------------------------------------------------------------- Verbinden

  /// Verbindet mit [id] und haelt die Verbindung: bei Abbruch oder
  /// Fehlschlag wird mit wachsender Wartezeit (max. 15 s) neu versucht,
  /// bis [disconnect] aufgerufen wird.
  Future<void> connect(String id, {String? name}) async {
    final session = ++_session;
    _wantedId = id;
    _wantedName = name;
    await stopScan();
    await _dropCurrent();
    await _connectLoop(session);
  }

  /// Trennt und beendet das automatische Wiederverbinden.
  Future<void> disconnect() async {
    _session++;
    _wantedId = null;
    _wantedName = null;
    await _dropCurrent();
    _emit(const BleLinkState());
  }

  bool _alive(int session) =>
      !_disposed && session == _session && _wantedId != null;

  Future<void> _connectLoop(int session) async {
    var attempt = 0;
    String? lastError;
    while (_alive(session)) {
      _emit(BleLinkState(
        status: attempt == 0 ? BleStatus.connecting : BleStatus.reconnecting,
        deviceId: _wantedId,
        deviceName: _wantedName,
        attempt: attempt,
        error: lastError,
      ));
      try {
        await _connectOnce(session);
        return; // Danach meldet der connectionState-Listener jeden Abbruch.
      } catch (e) {
        if (!_alive(session)) return;
        lastError = _short(e);
        debugPrint('[BLE] Versuch ${attempt + 1} fehlgeschlagen: $lastError');
        await _dropCurrent();
        attempt++;
        _emit(BleLinkState(
          status: BleStatus.reconnecting,
          deviceId: _wantedId,
          deviceName: _wantedName,
          attempt: attempt,
          error: lastError,
        ));
        await Future<void>.delayed(Duration(seconds: math.min(15, 2 * attempt)));
      }
    }
  }

  Future<void> _connectOnce(int session) async {
    final device = BluetoothDevice.fromId(_wantedId!);
    _device = device;

    // License.nonprofit = private Nutzung, Non-Profit, Bildung (kostenlos).
    // Bei kommerzieller Nutzung waere License.commercial samt Lizenz noetig.
    await device.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
      mtu: 247,
    );
    if (!_alive(session)) {
      await _safeDisconnect(device);
      return;
    }

    final services = await device.discoverServices();
    final serviceId = Guid(kBleServiceUuid);
    final rxId = Guid(kBleRxUuid);
    BluetoothCharacteristic? rx;
    for (final s in services) {
      if (s.uuid != serviceId) continue;
      for (final c in s.characteristics) {
        if (c.uuid == rxId) rx = c;
      }
    }
    if (rx == null) {
      throw const BleException(
          'Retro-Navi-Dienst nicht gefunden (falsches Gerät oder falscher Sketch?)');
    }
    if (!_alive(session)) {
      await _safeDisconnect(device);
      return;
    }

    _rx = rx;
    _connSub = device.connectionState.listen((s) {
      if (s != BluetoothConnectionState.disconnected || !_alive(session)) return;
      _rx = null;
      _connSub?.cancel();
      _connSub = null;
      _emit(BleLinkState(
        status: BleStatus.reconnecting,
        deviceId: _wantedId,
        deviceName: _wantedName,
        error: 'Verbindung verloren',
      ));
      unawaited(_connectLoop(session));
    });

    _emit(BleLinkState(
      status: BleStatus.connected,
      deviceId: _wantedId,
      deviceName: _wantedName,
      mtu: device.mtuNow,
    ));
  }

  Future<void> _dropCurrent() async {
    _rx = null;
    await _connSub?.cancel();
    _connSub = null;
    final d = _device;
    _device = null;
    if (d != null) await _safeDisconnect(d);
  }

  Future<void> _safeDisconnect(BluetoothDevice d) async {
    try {
      await d.disconnect();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- Senden

  /// Sendet [payload] plus Zeilenende. Laeuft noch eine Uebertragung, wird
  /// die neue Nachricht verworfen: Der Sekundentakt soll nie einen Stau
  /// aufbauen, und die naechste Nachricht ist ohnehin aktueller.
  @override
  Future<void> write(String payload) async {
    final rx = _rx;
    final device = _device;
    if (rx == null || device == null || !isReady) return;
    if (_writing) return;
    _writing = true;
    try {
      final bytes = utf8.encode('$payload$kBleLineEnd');
      final chunkSize = math.max(20, device.mtuNow - 3);
      final noResponse = rx.properties.writeWithoutResponse;
      for (final chunk in splitIntoChunks(bytes, chunkSize)) {
        await rx.write(chunk, withoutResponse: noResponse);
      }
    } finally {
      _writing = false;
    }
  }

  // ----------------------------------------------------------------- Rest

  void _emit(BleLinkState s) {
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  static String _short(Object e) {
    final t = e is BleException ? e.message : e.toString();
    return t.length > 120 ? '${t.substring(0, 120)}...' : t;
  }

  void dispose() {
    _disposed = true;
    _session++;
    unawaited(_dropCurrent());
    _stateCtrl.close();
  }
}
