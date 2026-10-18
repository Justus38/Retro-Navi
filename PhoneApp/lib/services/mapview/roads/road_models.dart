import 'mvt_decoder.dart';

/// Strassenklassen auf dem ESP32: 1 = Nebenstrasse, 2 = Hauptstrasse.
const roadClassSide = 1;
const roadClassMain = 2;

/// Ordnet den Wert "class" der OpenMapTiles-Ebene "transportation" zu.
/// 0 = wird nicht gezeichnet (Parkplatzwege, Feldwege, Pfade, Bahn ...).
int roadClassCode(String c) => switch (c) {
      'motorway' || 'trunk' || 'primary' || 'secondary' || 'tertiary' => roadClassMain,
      'minor' => roadClassSide,
      _ => 0,
    };

/// Ein Strassenabschnitt im lokalen Koordinatensystem (ganze Meter).
class RoadRun {
  const RoadRun(this.cls, this.pts);

  final int cls;

  /// Flach: x0, y0, x1, y1, ...
  final List<int> pts;

  int get pointCount => pts.length ~/ 2;
}

/// Eine dekodierte Kachel samt Position im Kachelraster.
class RoadTile {
  const RoadTile(this.z, this.x, this.y, this.layer);

  final int z;
  final int x;
  final int y;
  final MvtLayer layer;
}

/// Quelle fuer Vektorkacheln. Liefert null fuer leere Kacheln (z. B. Meer).
abstract interface class RoadTileSource {
  Future<RoadTile?> tile(int z, int x, int y);
}
