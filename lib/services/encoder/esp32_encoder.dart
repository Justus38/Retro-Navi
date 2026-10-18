import 'dart:convert';
import 'dart:math' as math;

import '../../core/models/nav_route.dart';
import '../../core/models/navigation_state.dart';
import '../mapview/map_models.dart';
import '../mapview/roads/road_models.dart';

/// Wandelt den [NavigationState] in das kompakte JSON fuer den ESP32:
/// {"spd":47,"turn":"L","dist":320,"street":"Hauptstr","rem":12400,"eta":18}
///
/// spd    km/h (ganzzahlig)
/// turn   S, L, R, SL, SR, U, ROUND1-4, ARR
/// dist   Meter bis zum naechsten Manoever
/// street ASCII-Strassenname, gekuerzt
/// rem    Restdistanz in Metern
/// eta    Restzeit in Minuten (aufgerundet)
class Esp32Encoder {
  const Esp32Encoder({this.maxStreetLength = 16});

  /// Maximale Laenge des Strassennamens (Zeichen, nur ASCII).
  final int maxStreetLength;

  /// Mit [pose] kommen sechs Felder dazu (Kartenansicht); ohne bleibt die
  /// Nachricht exakt wie in Phase 1.
  ///   m  Kennung des Chunks, zu dem x/y gehoeren
  ///   x  Meter nach Osten, y Meter nach Norden (im Chunk-System)
  ///   h  Fahrtrichtung in Grad (0 = Norden)
  ///   z  Sichtweite nach vorn in Metern
  ///   i  Index des ersten Chunk-Punkts vor dem Fahrzeug
  String encode(NavigationState s, {MapPose? pose}) {
    final m = <String, Object>{
      'spd': _int(s.speedKmh, max: 999),
      'turn': turnCode(s.turn, exitNumber: s.exitNumber),
      'dist': _int(s.distToTurnM),
      'street': sanitizeStreet(s.street),
      'rem': _int(s.remainingM),
      'eta': _int(s.remainingS > 0 ? (s.remainingS / 60).ceilToDouble() : 0),
    };
    if (pose != null) {
      m['m'] = pose.chunkId;
      m['x'] = _meters(pose.x);
      m['y'] = _meters(pose.y);
      m['h'] = pose.headingDeg;
      m['z'] = pose.zoomM;
      m['i'] = pose.nextIndex;
    }
    return jsonEncode(m);
  }

  /// Kartenstueck fuer den ESP32:
  /// {"t":"map","id":3,"e":0,"r":[x0,y0,x1,y1,...]}
  ///   id  Kennung, e = 1 wenn der letzte Punkt das Ziel ist,
  ///   r   Streckenpunkte in ganzen Metern (x Ost, y Nord).
  ///   fr  Kennung des Koordinatensystems (nur wenn Nebenstrassen moeglich sind)
  String encodeMapChunk(MapChunk c) => jsonEncode(<String, Object>{
        't': 'map',
        'id': c.id,
        if (c.frameId > 0) 'fr': c.frameId,
        'e': c.routeEnd ? 1 : 0,
        'r': c.route,
      });

  /// Nebenstrassen als Folge kleiner Nachrichten (jede passt in einen
  /// BLE-Zeilenpuffer des ESP32):
  /// {"t":"rd","fr":2,"g":5,"n":0,"f":0,"l":[[1,x0,y0,dx1,dy1,...],...]}
  ///   fr  Koordinatensystem (muss zum Chunk passen)
  ///   g   Ausgabe-Nummer; n = laufende Nummer des Teils (ab 0)
  ///   f   1 = letzter Teil, dann schaltet der ESP32 auf die neuen Strassen um
  ///   l   Abschnitte: Klasse (1 Neben, 2 Haupt), erster Punkt absolut,
  ///       danach nur Unterschiede zum Vorgaenger (ganze Meter)
  /// Eine leere Liste mit f=1 loescht die Strassen.
  List<String> encodeRoadParts(
    List<RoadRun> runs, {
    required int frameId,
    required int generation,
    int maxChars = 1000,
  }) {
    final parts = <String>[];
    var current = <List<int>>[];
    var size = 0;

    void emit(bool last) {
      parts.add(jsonEncode(<String, Object>{
        't': 'rd',
        'fr': frameId,
        'g': generation,
        'n': parts.length,
        'f': last ? 1 : 0,
        'l': current,
      }));
      current = <List<int>>[];
      size = 0;
    }

    for (final r in runs) {
      final row = <int>[r.cls, r.pts[0], r.pts[1]];
      for (var i = 2; i < r.pts.length; i += 2) {
        row
          ..add(r.pts[i] - r.pts[i - 2])
          ..add(r.pts[i + 1] - r.pts[i - 1]);
      }
      final cost = jsonEncode(row).length + 1;
      if (current.isNotEmpty && size + cost > maxChars) emit(false);
      current.add(row);
      size += cost;
    }
    emit(true);
    return parts;
  }

  /// Meter mit hoechstens einer Nachkommastelle; ganze Werte ohne ".0".
  static num _meters(double v) {
    if (!v.isFinite) return 0;
    final r = (v * 10).round() / 10;
    return r == r.roundToDouble() ? r.round() : r;
  }

  /// Abbiegecode fuer das Display.
  /// - scharfe und normale Kurven -> L / R
  /// - leichte Kurven und "links/rechts halten" -> SL / SR
  /// - Kreisverkehr -> ROUND1..4 (ab der 4. Ausfahrt immer ROUND4);
  ///   ohne bekannte Ausfahrt -> S
  static String turnCode(TurnType type, {int? exitNumber}) => switch (type) {
        TurnType.left || TurnType.sharpLeft => 'L',
        TurnType.right || TurnType.sharpRight => 'R',
        TurnType.slightLeft || TurnType.keepLeft => 'SL',
        TurnType.slightRight || TurnType.keepRight => 'SR',
        TurnType.straight || TurnType.depart || TurnType.exitRoundabout => 'S',
        TurnType.uTurn => 'U',
        TurnType.goal => 'ARR',
        TurnType.enterRoundabout => exitNumber == null
            ? 'S'
            : 'ROUND${math.max(1, math.min(4, exitNumber))}',
      };

  /// Macht aus einem Strassennamen reines ASCII, kuerzt "Strasse" zu "Str"
  /// und schneidet auf [maxStreetLength] Zeichen ab.
  String sanitizeStreet(String input) {
    var t = input.trim();
    const replacements = {
      'ä': 'ae', 'ö': 'oe', 'ü': 'ue', 'Ä': 'Ae', 'Ö': 'Oe', 'Ü': 'Ue', 'ß': 'ss',
      'é': 'e', 'è': 'e', 'ê': 'e', 'à': 'a', 'â': 'a', 'ô': 'o', 'ç': 'c',
      'É': 'E', 'ñ': 'n', 'ø': 'o', 'å': 'a', 'æ': 'ae', 'ł': 'l', 'š': 's',
      'č': 'c', 'ž': 'z', 'ý': 'y',
    };
    replacements.forEach((from, to) => t = t.replaceAll(from, to));

    // "Hauptstrasse" -> "Hauptstr", "Strasse des 17. Juni" -> "Str des 17. Juni"
    t = t.replaceAllMapped(
      RegExp(r'strasse(?![a-z])', caseSensitive: false),
      (m) {
        final atWordStart = m.start == 0 || !_isLetter(t.codeUnitAt(m.start - 1));
        return atWordStart ? 'Str' : 'str';
      },
    );

    // Alles ausser druckbarem ASCII entfernen, Leerraum zusammenfassen.
    t = t.replaceAll(RegExp(r'[^\x20-\x7E]'), '').replaceAll(RegExp(r'\s+'), ' ').trim();

    if (t.length > maxStreetLength) {
      t = t.substring(0, maxStreetLength).trimRight();
    }
    return t;
  }

  static bool _isLetter(int c) =>
      (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

  static int _int(double v, {int max = 9999999}) {
    if (!v.isFinite) return 0;
    return math.max(0, math.min(max, v.round()));
  }
}
