import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/models/gps_fix.dart';
import '../core/models/navigation_state.dart';
import '../services/navigation/navigation_engine.dart';
import 'geocoding_providers.dart';
import 'gps_providers.dart';
import 'position_providers.dart';
import 'routing_providers.dart';
import 'simulation_providers.dart';

/// Verbindet GPS-Strom, NavigationEngine und automatische Neuberechnung.
class NavigationController extends Notifier<NavigationState> {
  static const _rerouteCooldown = Duration(seconds: 8);

  NavigationEngine? _engine;
  DateTime? _lastReroute;
  bool _rerouting = false;
  int _rerouteCount = 0;

  @override
  NavigationState build() {
    // Jede neue Position durch die Engine schicken.
    ref.listen(positionStreamProvider, (_, next) {
      final fix = next.valueOrNull;
      if (fix != null) _onFix(fix);
    });

    // Umschalten GPS <-> Simulation beendet eine laufende Navigation.
    ref.listen(simulationProvider.select((s) => s.enabled), (_, __) {
      if (state.active) stop();
    });

    // Neue Route waehrend der Fahrt (Neuberechnung) -> neue Engine.
    // Route weg (Ziel geloescht/geaendert) -> Navigation beenden.
    ref.listen(routeProvider.select((r) => r.valueOrNull), (prev, next) {
      // Die Simulation faehrt immer die aktuelle Route ab.
      ref.read(simulationProvider.notifier).loadRoute(next);
      if (!state.active) return;
      if (next == null) {
        stop();
      } else if (next != prev) {
        _engine = NavigationEngine(next);
        final fix = ref.read(positionStreamProvider).valueOrNull;
        if (fix != null) _onFix(fix);
      }
    });

    return const NavigationState();
  }

  void start() {
    final route = ref.read(routeProvider).valueOrNull;
    if (route == null || route.points.length < 2) return;
    _engine = NavigationEngine(route);
    _lastReroute = null;
    _rerouting = false;
    _rerouteCount = 0;
    state = const NavigationState(active: true);
    // Echte Fahrt: Ortung auch bei gesperrtem Display (Vordergrunddienst).
    ref.read(backgroundTrackingProvider.notifier).state =
        !ref.read(simulationProvider).enabled;
    // In der Simulation startet die Fahrt mit der Navigation.
    if (ref.read(simulationProvider).enabled) {
      ref.read(simulationProvider.notifier)
        ..restart()
        ..play();
    }
    final fix = ref.read(positionStreamProvider).valueOrNull;
    if (fix != null) _onFix(fix);
  }

  void stop() {
    if (ref.read(simulationProvider).enabled) {
      ref.read(simulationProvider.notifier).pause();
    }
    ref.read(backgroundTrackingProvider.notifier).state = false;
    _engine = null;
    _rerouting = false;
    state = const NavigationState();
  }

  void _onFix(GpsFix fix) {
    final engine = _engine;
    if (engine == null) return;

    final s = engine.update(fix);
    state = s.copyWith(rerouting: _rerouting, reroutes: _rerouteCount);
    if (s.offRoute && !s.arrived && !_rerouting) _reroute(fix.latLng);
  }

  Future<void> _reroute(LatLng from) async {
    final now = DateTime.now();
    final last = _lastReroute;
    if (last != null && now.difference(last) < _rerouteCooldown) return;
    if (ref.read(destinationSearchProvider).destination == null) return;

    _lastReroute = now;
    _rerouting = true;
    debugPrint('[Reroute] Abweichung erkannt, berechne neu ab $from');
    state = state.copyWith(rerouting: true, clearError: true);
    try {
      await ref.read(routeProvider.notifier).reroute(from: from);
      _rerouteCount++;
      debugPrint('[Reroute] neue Route uebernommen (#$_rerouteCount)');
      if (state.active) {
        state = state.copyWith(
            rerouting: false, reroutes: _rerouteCount, clearError: true);
      }
    } catch (e) {
      debugPrint('[Reroute] fehlgeschlagen: $e');
      if (state.active) {
        state = state.copyWith(
          rerouting: false,
          error: 'Neuberechnung fehlgeschlagen: $e',
        );
      }
    } finally {
      _rerouting = false;
    }
  }
}

final navigationProvider =
    NotifierProvider<NavigationController, NavigationState>(NavigationController.new);
