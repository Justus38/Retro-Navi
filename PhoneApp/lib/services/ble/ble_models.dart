enum BleStatus { idle, connecting, connected, reconnecting }

class BleException implements Exception {
  const BleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Gefundenes Geraet aus dem Scan.
class BleDevice {
  const BleDevice({
    required this.id,
    required this.name,
    required this.rssi,
    required this.isRetroNavi,
  });

  final String id;
  final String name;
  final int rssi;

  /// Meldet den Retro-Navi-Dienst oder traegt den passenden Namen.
  final bool isRetroNavi;
}

/// Zustand der Verbindung zum ESP32.
class BleLinkState {
  const BleLinkState({
    this.status = BleStatus.idle,
    this.deviceId,
    this.deviceName,
    this.mtu,
    this.attempt = 0,
    this.error,
  });

  final BleStatus status;
  final String? deviceId;
  final String? deviceName;
  final int? mtu;

  /// Anzahl der Verbindungsversuche seit dem letzten Abbruch.
  final int attempt;
  final String? error;

  String get label {
    final n = deviceName;
    if (n != null && n.isNotEmpty) return n;
    return deviceId ?? '';
  }
}
