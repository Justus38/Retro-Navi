import 'dart:math' as math;

/// Slippy-Map-Kachelrechnung (Web-Mercator).
int tileX(double lon, int z) =>
    ((lon + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);

int tileY(double lat, int z) {
  final r = lat.clamp(-85.05112878, 85.05112878) * math.pi / 180;
  final s = math.log(math.tan(r) + 1 / math.cos(r));
  return ((1 - s / math.pi) / 2 * (1 << z)).floor().clamp(0, (1 << z) - 1);
}

/// Laenge der Kachel [tx] in Grad Laengengrad -> Position eines Kachelpunkts.
double tileLon(int tx, double px, int extent, int z) =>
    (tx + px / extent) / (1 << z) * 360 - 180;

double tileLat(int ty, double py, int extent, int z) {
  final n = math.pi * (1 - 2 * (ty + py / extent) / (1 << z));
  return math.atan((math.exp(n) - math.exp(-n)) / 2) * 180 / math.pi;
}
