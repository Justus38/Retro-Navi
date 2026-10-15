import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/gps_fix.dart';
import 'gps_providers.dart';
import 'simulation_providers.dart';

/// DIE Positionsquelle der App: echtes GPS oder Simulation.
/// NavigationEngine, Karte und Routing lesen nur diesen Provider.
final positionStreamProvider = StreamProvider<GpsFix>((ref) async* {
  final simOn = ref.watch(simulationProvider.select((s) => s.enabled));
  if (simOn) {
    final sim = ref.watch(simulationServiceProvider);
    final cur = sim.current;
    if (cur != null) yield cur;
    yield* sim.stream;
  } else {
    yield* ref.watch(gpsStreamProvider.stream);
  }
});
