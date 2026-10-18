import 'dart:convert';
import 'dart:typed_data';

/// Eine Linie aus einer Vektorkachel (Kachelkoordinaten, 0..extent).
class MvtLine {
  const MvtLine(this.roadClass, this.coords);

  /// Wert der Eigenschaft "class" (z. B. "primary", "minor").
  final String roadClass;

  /// Flach: x0, y0, x1, y1, ...
  final Int32List coords;
}

class MvtLayer {
  const MvtLayer(this.extent, this.lines);

  /// Kantenlaenge des Koordinatenrasters der Kachel (meist 4096).
  final int extent;
  final List<MvtLine> lines;
}

/// Minimaler Decoder fuer Mapbox Vector Tiles (Protobuf, Spezifikation 2.1).
///
/// Liest nur, was die Navigation braucht: LINESTRING-Objekte einer Ebene mit
/// ihrer String-Eigenschaft "class". Alles andere wird uebersprungen.
/// Bewusst ohne externes Paket.
///
/// Liefert null, wenn die Kachel die Ebene nicht enthaelt.
MvtLayer? decodeMvtLines(Uint8List bytes, String layerName) {
  final r = _Reader(bytes, 0, bytes.length);
  while (r.hasMore) {
    final tag = r.varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 3 && wire == 2) {
      final len = r.varint();
      final end = r.pos + len;
      final layer = _decodeLayer(bytes, r.pos, end, layerName);
      r.pos = end;
      if (layer != null) return layer;
    } else {
      r.skip(wire);
    }
  }
  return null;
}

MvtLayer? _decodeLayer(Uint8List b, int start, int end, String wanted) {
  final r = _Reader(b, start, end);
  var name = '';
  var extent = 4096;
  final keys = <String>[];
  final values = <String?>[];
  final features = <(int, int)>[];

  while (r.hasMore) {
    final tag = r.varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 1 && wire == 2) {
      name = r.string();
    } else if (field == 2 && wire == 2) {
      final len = r.varint();
      features.add((r.pos, r.pos + len));
      r.pos += len;
    } else if (field == 3 && wire == 2) {
      keys.add(r.string());
    } else if (field == 4 && wire == 2) {
      final len = r.varint();
      values.add(_decodeStringValue(b, r.pos, r.pos + len));
      r.pos += len;
    } else if (field == 5 && wire == 0) {
      extent = r.varint();
    } else {
      r.skip(wire);
    }
  }
  if (name != wanted) return null;

  final classKey = keys.indexOf('class');
  final lines = <MvtLine>[];
  if (classKey >= 0) {
    for (final (fs, fe) in features) {
      _decodeFeature(b, fs, fe, classKey, values, lines);
    }
  }
  return MvtLayer(extent, lines);
}

/// Value-Nachricht: nur der String (Feld 1) interessiert, alles andere -> null.
String? _decodeStringValue(Uint8List b, int start, int end) {
  final r = _Reader(b, start, end);
  while (r.hasMore) {
    final tag = r.varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 1 && wire == 2) return r.string();
    r.skip(wire);
  }
  return null;
}

void _decodeFeature(
  Uint8List b,
  int start,
  int end,
  int classKey,
  List<String?> values,
  List<MvtLine> out,
) {
  final r = _Reader(b, start, end);
  var type = 0;
  final tags = <int>[];
  final geom = <int>[];

  void readPacked(int wire, List<int> into) {
    if (wire == 2) {
      final len = r.varint();
      final e = r.pos + len;
      while (r.pos < e) {
        into.add(r.varint());
      }
    } else if (wire == 0) {
      into.add(r.varint());
    } else {
      r.skip(wire);
    }
  }

  while (r.hasMore) {
    final tag = r.varint();
    final field = tag >> 3;
    final wire = tag & 7;
    if (field == 2) {
      readPacked(wire, tags);
    } else if (field == 3 && wire == 0) {
      type = r.varint();
    } else if (field == 4) {
      readPacked(wire, geom);
    } else {
      r.skip(wire);
    }
  }
  if (type != 2) return; // nur LINESTRING

  String? cls;
  for (var i = 0; i + 1 < tags.length; i += 2) {
    if (tags[i] == classKey) {
      final v = tags[i + 1];
      if (v >= 0 && v < values.length) cls = values[v];
    }
  }
  if (cls == null) return;

  // Geometrie: Befehle MoveTo(1) / LineTo(2) / ClosePath(7), Parameter zickzack-
  // kodierte Differenzen zum letzten Punkt.
  var x = 0;
  var y = 0;
  var i = 0;
  var cur = <int>[];
  void flush() {
    if (cur.length >= 4) out.add(MvtLine(cls!, Int32List.fromList(cur)));
    cur = <int>[];
  }

  while (i < geom.length) {
    final cmdInt = geom[i++];
    final cmd = cmdInt & 7;
    final count = cmdInt >> 3;
    if (cmd == 1 || cmd == 2) {
      for (var k = 0; k < count; k++) {
        if (i + 2 > geom.length) break; // abgeschnittene Geometrie
        x +=_zigzag(geom[i++]);
        y += _zigzag(geom[i++]);
        if (cmd == 1) flush();
        cur
          ..add(x)
          ..add(y);
      }
    } else if (cmd == 7) {
      // ClosePath kommt bei Linien nicht vor.
    } else {
      break; // unbekannter Befehl: Rest verwerfen
    }
  }
  flush();
}

int _zigzag(int n) => (n >> 1) ^ -(n & 1);

class _Reader {
  _Reader(this.b, this.pos, this.end) {
    if (pos < 0 || end > b.length || pos > end) {
      throw const FormatException('Kachel: Laenge passt nicht zu den Daten');
    }
  }

  final Uint8List b;
  int pos;
  final int end;

  bool get hasMore => pos < end;

  int varint() {
    var result = 0;
    var shift = 0;
    while (true) {
      if (pos >= end) throw const FormatException('Kachel: unerwartetes Ende');
      final byte = b[pos++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
      if (shift > 63) throw const FormatException('Kachel: Varint zu lang');
    }
  }

  String string() {
    final len = varint();
    if (pos + len > end) throw const FormatException('Kachel: String zu lang');
    final s = utf8.decode(Uint8List.sublistView(b, pos, pos + len), allowMalformed: true);
    pos += len;
    return s;
  }

  void skip(int wire) {
    switch (wire) {
      case 0:
        varint();
      case 1:
        pos += 8;
      case 2:
        final len = varint();
        pos += len;
      case 5:
        pos += 4;
      default:
        throw FormatException('Kachel: unbekannter Wire-Typ $wire');
    }
    if (pos > end) throw const FormatException('Kachel: Feld ueber das Ende hinaus');
  }
}
