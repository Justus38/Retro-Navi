import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/models/nav_route.dart';
import '../services/simulation/simulation_service.dart';
import 'gps_providers.dart';

final simulationServiceProvider = Provider<SimulationService>((ref) {
  final service = SimulationService();
  ref.onDispose(service.dispose);
  return service;
});

class SimulationState {
  const SimulationState({
    this.enabled = false,
    this.playing = false,
    this.speedKmh = 50,
    this.offRoute = false,
    this.hasPosition = false,
    this.hasRoute = false,
  });

  final bool enabled;
  final bool playing;
  final double speedKmh;

  /// Seitlicher Versatz zum Testen der Neuberechnung ist aktiv.
  final bool offRoute;
  final bool hasPosition;
  final bool hasRoute;
}

class SimulationController extends Notifier<SimulationState> {
  SimulationService get _s => ref.read(simulationServiceProvider);

  @override
  SimulationState build() {
    _s.onFinished = _sync;
    return const SimulationState();
  }

  SimulationState _snapshot({bool? enabled}) => SimulationState(
        enabled: enabled ?? state.enabled,
        playing: _s.playing,
        speedKmh: _s.speedKmh,
        offRoute: _s.lateralOffsetActive,
        hasPosition: _s.current != null,
        hasRoute: _s.hasRoute,
      );

  void _sync() => state = _snapshot();

  void setEnabled(bool on) {
    if (on == state.enabled) return;
    if (on) {
      // Ohne Route am letzten echten GPS-Punkt "parken" (falls vorhanden).
      final real = ref.read(lastRealFixProvider);
      if (!_s.hasRoute && real != null) {
        _s.parkAt(real.latLng, heading: real.hasHeading ? real.heading : 0);
      }
      _s.start();
      state = _snapshot(enabled: true);
    } else {
      _s.stop();
      state = _snapshot(enabled: false);
    }
  }

  /// Virtuellen Startpunkt setzen (Langdruck auf die Karte).
  void setStart(LatLng position) {
    _s.parkAt(position);
    _sync();
  }

  /// Wird bei jeder neuen Route aufgerufen (auch bei Neuberechnung).
  void loadRoute(NavRoute? route) {
    _s.loadRoute(route);
    _sync();
  }

  void play() {
    _s.play();
    _sync();
  }

  void pause() {
    _s.pause();
    _sync();
  }

  void restart() {
    _s.restart();
    _sync();
  }

  void setSpeed(double kmh) {
    _s.setSpeed(kmh);
    _sync();
  }

  void toggleOffRoute() {
    _s.toggleLateralOffset();
    _sync();
  }
}

final simulationProvider =
    NotifierProvider<SimulationController, SimulationState>(SimulationController.new);
