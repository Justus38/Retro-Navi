import 'package:flutter_test/flutter_test.dart';
import 'package:retro_navi/services/ble/ble_chunker.dart';

void main() {
  test('kurze Nachricht bleibt ein Stueck', () {
    final chunks = splitIntoChunks(List.generate(50, (i) => i), 244);
    expect(chunks.length, 1);
    expect(chunks.first.length, 50);
  });

  test('lange Nachricht wird in MTU-grosse Stuecke zerlegt, Reihenfolge bleibt', () {
    final data = List.generate(111, (i) => i);
    final chunks = splitIntoChunks(data, 20);
    expect(chunks.map((c) => c.length).toList(), [20, 20, 20, 20, 20, 11]);
    expect(chunks.expand((c) => c).toList(), data);
  });

  test('genau ein Vielfaches der Stueckgroesse', () {
    final chunks = splitIntoChunks(List.filled(40, 1), 20);
    expect(chunks.length, 2);
  });

  test('leere Daten und ungueltige Groesse', () {
    expect(splitIntoChunks(const [], 20), isEmpty);
    expect(() => splitIntoChunks(const [1], 0), throwsArgumentError);
  });
}
