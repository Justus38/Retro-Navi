import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:retro_navi/core/models/nav_route.dart';
import 'package:retro_navi/core/models/navigation_state.dart';
import 'package:retro_navi/services/encoder/esp32_encoder.dart';

NavigationState _state({
  double speedKmh = 47.2,
  TurnType turn = TurnType.left,
  double dist = 320.4,
  String street = 'Hauptstr',
  double remM = 12400.3,
  double remS = 1060,
  int? exit,
}) =>
    NavigationState(
      active: true,
      speedKmh: speedKmh,
      turn: turn,
      distToTurnM: dist,
      street: street,
      remainingM: remM,
      remainingS: remS,
      exitNumber: exit,
    );

void main() {
  const enc = Esp32Encoder();

  test('Beispiel aus der Spezifikation (exaktes Format)', () {
    expect(
      enc.encode(_state()),
      '{"spd":47,"turn":"L","dist":320,"street":"Hauptstr","rem":12400,"eta":18}',
    );
  });

  test('Abbiegecodes', () {
    const expected = {
      TurnType.left: 'L',
      TurnType.right: 'R',
      TurnType.sharpLeft: 'L',
      TurnType.sharpRight: 'R',
      TurnType.slightLeft: 'SL',
      TurnType.slightRight: 'SR',
      TurnType.keepLeft: 'SL',
      TurnType.keepRight: 'SR',
      TurnType.straight: 'S',
      TurnType.depart: 'S',
      TurnType.exitRoundabout: 'S',
      TurnType.uTurn: 'U',
      TurnType.goal: 'ARR',
    };
    expected.forEach((type, code) {
      expect(Esp32Encoder.turnCode(type), code, reason: '$type');
    });
  });

  test('Kreisverkehr: ROUND1-4, darueber ROUND4, unbekannt S', () {
    String code(int? e) =>
        Esp32Encoder.turnCode(TurnType.enterRoundabout, exitNumber: e);
    expect(code(1), 'ROUND1');
    expect(code(3), 'ROUND3');
    expect(code(4), 'ROUND4');
    expect(code(7), 'ROUND4');
    expect(code(0), 'ROUND1');
    expect(code(null), 'S');
  });

  test('Strassennamen: Umlaute, Strasse -> Str, Kuerzung', () {
    expect(enc.sanitizeStreet('Hauptstraße'), 'Hauptstr');
    expect(enc.sanitizeStreet('Straße des 17. Juni'), 'Str des 17. Juni');
    expect(enc.sanitizeStreet('Bürgermeister-Ulrich-Straße'), 'Buergermeister-U');
    expect(enc.sanitizeStreet('Müllerstrasse'), 'Muellerstr');
    expect(enc.sanitizeStreet('Strassenweg'), 'Strassenweg');
    expect(enc.sanitizeStreet('  A  8  '), 'A 8');
    expect(enc.sanitizeStreet(''), '');
  });

  test('Anfuehrungszeichen im Namen ergeben weiterhin gueltiges JSON', () {
    final json = enc.encode(_state(street: 'Am "Eck"'));
    final map = jsonDecode(json) as Map<String, dynamic>;
    expect(map['street'], 'Am "Eck"');
  });

  test('ETA wird aufgerundet, 0 bleibt 0', () {
    Map<String, dynamic> m(double s) =>
        jsonDecode(enc.encode(_state(remS: s))) as Map<String, dynamic>;
    expect(m(0)['eta'], 0);
    expect(m(30)['eta'], 1);
    expect(m(60)['eta'], 1);
    expect(m(61)['eta'], 2);
  });

  test('ungueltige Zahlen werden zu 0', () {
    final m = jsonDecode(enc.encode(_state(speedKmh: double.nan, dist: double.infinity)))
        as Map<String, dynamic>;
    expect(m['spd'], 0);
    expect(m['dist'], 0);
  });

  test('Nachricht bleibt auch im Extremfall unter 110 Bytes', () {
    final json = enc.encode(_state(
      speedKmh: 250,
      turn: TurnType.enterRoundabout,
      exit: 4,
      dist: 99999,
      street: 'Bürgermeister-Ulrich-Straße',
      remM: 999999,
      remS: 99999 * 60,
    ));
    expect(utf8.encode(json).length, lessThan(110));
  });
}
