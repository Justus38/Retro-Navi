import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/gps_fix.dart';
import '../services/gps/gps_service.dart';

final gpsServiceProvider = Provider<GpsService>((ref) => GpsService());

/// Berechtigungsstatus. Mit `ref.invalidate(...)` erneut pruefen.
final gpsPermissionProvider = FutureProvider<GpsPermissionStatus>(
  (ref) => ref.watch(gpsServiceProvider).ensurePermission(),
);

/// true, solange navigiert wird: schaltet den Hintergrundbetrieb der Ortung
/// ein (Vordergrunddienst auf Android).
final backgroundTrackingProvider = StateProvider<bool>((ref) => false);

/// Letzter echter GPS-Fix (wird von der Positionsquelle gepflegt). Die
/// Simulation nutzt ihn als Startpunkt.
final lastRealFixProvider = StateProvider<GpsFix?>((ref) => null);
