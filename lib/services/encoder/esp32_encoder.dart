import 'dart:convert';
import 'dart:math' as math;

import '../../core/models/nav_route.dart';
import '../../core/models/navigation_state.dart';

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

  String encode(NavigationState s) {
    return jsonEncode(<String, Object>{
      'spd': _int(s.speedKmh, max: 999),
      'turn': turnCode(s.turn, exitNumber: s.exitNumber),
      'dist': _int(s.distToTurnM),
      'street': sanitizeStreet(s.street),
      'rem': _int(s.remainingM),
      'eta': _int(s.remainingS > 0 ? (s.remainingS / 60).ceilToDouble() : 0),
    });
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
