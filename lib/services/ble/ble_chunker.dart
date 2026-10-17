import 'dart:math' as math;

/// Zerlegt [data] in Stuecke von hoechstens [maxLen] Bytes (Reihenfolge bleibt).
/// BLE darf pro Schreibvorgang nur MTU-3 Bytes uebertragen.
List<List<int>> splitIntoChunks(List<int> data, int maxLen) {
  if (maxLen < 1) throw ArgumentError.value(maxLen, 'maxLen', 'muss >= 1 sein');
  if (data.isEmpty) return const [];
  return [
    for (var i = 0; i < data.length; i += maxLen)
      data.sublist(i, math.min(i + maxLen, data.length)),
  ];
}
