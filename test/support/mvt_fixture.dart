import 'dart:convert';
import 'dart:typed_data';

/// Baut Mapbox-Vector-Tile-Bytes von Hand (nur fuer Tests): eine Ebene mit
/// Linien (und optional einem Polygon), Eigenschaft "class".

List<int> _varint(int v) {
  final out = <int>[];
  var n = v;
  while (n >= 0x80) {
    out.add((n & 0x7f) | 0x80);
    n >>= 7;
  }
  out.add(n);
  return out;
}

List<int> _tag(int field, int wire) => _varint((field << 3) | wire);

List<int> _bytes(int field, List<int> payload) =>
    [..._tag(field, 2), ..._varint(payload.length), ...payload];

List<int> _string(int field, String s) => _bytes(field, utf8.encode(s));

int _zigzag(int n) => (n << 1) ^ (n >> 63);

/// Linien eines Objekts als MVT-Geometrie. Der Cursor laeuft ueber alle Linien
/// des Objekts weiter (wie in der Spezifikation).
List<int> geometry(List<List<int>> lines) {
  final out = <int>[];
  var cx = 0, cy = 0;
  for (final l in lines) {
    final n = l.length ~/ 2;
    out.addAll(_varint((1 << 3) | 1)); // MoveTo, 1 Punkt
    out.addAll(_varint(_zigzag(l[0] - cx)));
    out.addAll(_varint(_zigzag(l[1] - cy)));
    cx = l[0];
    cy = l[1];
    out.addAll(_varint(((n - 1) << 3) | 2)); // LineTo
    for (var i = 1; i < n; i++) {
      out.addAll(_varint(_zigzag(l[2 * i] - cx)));
      out.addAll(_varint(_zigzag(l[2 * i + 1] - cy)));
      cx = l[2 * i];
      cy = l[2 * i + 1];
    }
  }
  return out;
}

List<int> _packed(int field, List<int> values) =>
    _bytes(field, [for (final v in values) ..._varint(v)]);

class FixtureFeature {
  const FixtureFeature(this.roadClass, this.lines, {this.type = 2});
  final String roadClass;
  final List<List<int>> lines;

  /// 2 = Linie, 3 = Polygon.
  final int type;
}

/// Eine Kachel mit einer zusaetzlichen Ebene "water" (muss uebersprungen
/// werden) und der Ebene [layerName].
Uint8List buildTile(List<FixtureFeature> features,
    {String layerName = 'transportation', int extent = 4096}) {
  final classes = <String>[];
  for (final f in features) {
    if (!classes.contains(f.roadClass)) classes.add(f.roadClass);
  }

  final layer = <int>[
    ..._string(1, layerName),
    for (final f in features)
      ..._bytes(2, [
        ..._packed(2, [0, classes.indexOf(f.roadClass)]),
        ..._tag(3, 0),
        ..._varint(f.type),
        ..._packed(4, geometry(f.lines)),
      ]),
    ..._string(3, 'class'),
    for (final c in classes) ..._bytes(4, _string(1, c)),
    ..._tag(5, 0),
    ..._varint(extent),
    ..._tag(15, 0),
    ..._varint(2),
  ];

  final water = <int>[
    ..._string(1, 'water'),
    ..._string(3, 'class'),
    ..._bytes(4, _string(1, 'lake')),
    ..._tag(5, 0),
    ..._varint(4096),
  ];

  return Uint8List.fromList([..._bytes(3, water), ..._bytes(3, layer)]);
}
