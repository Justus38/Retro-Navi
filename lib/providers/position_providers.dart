import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/gps_fix.dart';
import '../services/gps/gps_service.dart';
import 'gps_providers.dart';
import 'simulation_providers.dart';

/// DIE Positionsquelle der App: echtes GPS oder Simulation.
/// NavigationEngine, Karte und Routing lesen nur diesen Provider.
///
/// Wechselt der Hintergrundmodus (Navigation an/aus) oder die Simulation,
/// laeuft diese Funktion neu und baut den GPS-Strom selbst neu auf.
final positionStreamProvider = StreamProvider<GpsFix>((ref) async* {
  final simOn = ref.watch(simulationProvider.select((s) => s.enabled));
  if (simOn) {
    final sim = ref.watch(simulationServiceProvider);
    final cur = sim.current;
    if (cur != null) yield cur;
    yield* sim.stream;
    return;
  }

  var disposed = false;
  ref.onDispose(() => disposed = true);

  final background = ref.watch(backgroundTrackingProvider);
  final gps = ref.watch(gpsServiceProvider);
  final status = await ref.watch(gpsPermissionProvider.future);
  if (status != GpsPermissionStatus.granted) return;

  var useBackground = background;
  while (!disposed) {
    try {
      await for (final fix in gps.positionStream(background: useBackground)) {
        if (disposed) return;
        ref.read(lastRealFixProvider.notifier).state = fix;
        yield fix;
      }
      return;
    } catch (e) {
      // Faellt der Hintergrunddienst aus (z. B. fehlende Berechtigung im
      // Manifest), weiter mit normaler Ortung statt ganz ohne Position.
      if (!useBackground || disposed) rethrow;
      debugPrint('[GPS] Hintergrundmodus nicht moeglich ($e), weiter im Vordergrund');
      useBackground = false;
    }
  }
});
