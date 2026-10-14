import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config/app_config.dart';
import 'ui/map/map_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = await AppConfig.load();
  runApp(
    ProviderScope(
      overrides: [appConfigProvider.overrideWithValue(config)],
      child: const RetroNaviApp(),
    ),
  );
}

class RetroNaviApp extends StatelessWidget {
  const RetroNaviApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Retro Navi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepOrange,
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}
