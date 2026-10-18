import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Konfiguration aus `assets/config/secrets.json` (nicht im Git).
/// Vorlage: `assets/config/secrets.example.json`.
class AppConfig {
  const AppConfig({required this.orsApiKey, required this.userAgent});

  final String orsApiKey;

  /// Nominatim und OSM-Tiles verlangen einen identifizierbaren User-Agent.
  final String userAgent;

  bool get hasOrsKey => orsApiKey.isNotEmpty && !orsApiKey.startsWith('DEIN_');

  static const _path = 'assets/config/secrets.json';

  static Future<AppConfig> load() async {
    try {
      final raw = await rootBundle.loadString(_path);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return AppConfig(
        orsApiKey: (json['orsApiKey'] as String?) ?? '',
        userAgent: (json['userAgent'] as String?) ?? 'RetroNavi/0.1',
      );
    } catch (_) {
      // secrets.json fehlt: App startet trotzdem (Schritt 1 braucht keinen Key).
      return const AppConfig(orsApiKey: '', userAgent: 'RetroNavi/0.1');
    }
  }
}

/// Wird in main() mit dem geladenen Wert ueberschrieben.
final appConfigProvider = Provider<AppConfig>(
  (ref) => throw UnimplementedError('appConfigProvider nicht initialisiert'),
);
