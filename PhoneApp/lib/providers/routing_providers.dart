import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../core/config/app_config.dart';
import '../core/models/nav_route.dart';
import '../services/routing/ors_routing_service.dart';
import '../services/routing/routing_service.dart';
import 'geocoding_providers.dart';
import 'gps_providers.dart';
import 'position_providers.dart';
import 'simulation_providers.dart';

final routingServiceProvider = Provider<RoutingService>((ref) {
  final config = ref.watch(appConfigProvider);
  return OrsRoutingService(ref.watch(httpClientProvider), config.orsApiKey);
});

/// Haelt die aktuell berechnete Route (null = keine).
class RouteController extends AsyncNotifier<NavRoute?> {
  @override
  FutureOr<NavRoute?> build() {
    // Ziel geaendert oder geloescht -> alte Route verwerfen.
    ref.listen(destinationSearchProvider.select((s) => s.destination), (prev, next) {
      if (prev != next) state = const AsyncData(null);
    });
    return null;
  }

  /// Berechnet die Route von der aktuellen GPS-Position zum gewaehlten Ziel.
  Future<void> calculate() async {
    final destination = ref.read(destinationSearchProvider).destination;
    if (destination == null) return;

    if (!ref.read(appConfigProvider).hasOrsKey) {
      state = AsyncError(
        const RoutingException('Kein ORS-Key in secrets.json eingetragen.'),
        StackTrace.current,
      );
      return;
    }

    state = const AsyncLoading();
    final result = await AsyncValue.guard(() async {
      final start = await _startPosition();
      return ref
          .read(routingServiceProvider)
          .route(from: start, to: destination.position);
    });

    // Ziel wurde waehrend der Berechnung geaendert -> Ergebnis verwerfen.
    if (ref.read(destinationSearchProvider).destination != destination) return;
    state = result;
  }

  /// Route verwerfen (z. B. weil der Startpunkt geaendert wurde).
  void clear() => state = const AsyncData(null);

  /// Neuberechnung waehrend der Fahrt: ersetzt die Route ohne Ladezustand,
  /// damit die Anzeige nicht flackert. Fehler gehen an den Aufrufer.
  Future<void> reroute({required LatLng from}) async {
    final destination = ref.read(destinationSearchProvider).destination;
    if (destination == null) return;
    final route = await ref
        .read(routingServiceProvider)
        .route(from: from, to: destination.position);
    if (ref.read(destinationSearchProvider).destination != destination) return;
    state = AsyncData(route);
  }

  Future<LatLng> _startPosition() async {
    final fix = ref.read(positionStreamProvider).valueOrNull;
    if (fix != null) return fix.latLng;
    if (ref.read(simulationProvider).enabled) {
      throw const RoutingException(
          'Simulation: kein Startpunkt. Karte lange drücken, um ihn zu setzen.');
    }
    try {
      return (await ref.read(gpsServiceProvider).getCurrent()).latLng;
    } catch (_) {
      throw const RoutingException('Noch keine GPS-Position für den Start.');
    }
  }
}

final routeProvider =
    AsyncNotifierProvider<RouteController, NavRoute?>(RouteController.new);
