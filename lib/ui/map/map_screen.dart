import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

import '../../core/config/app_config.dart';
import '../../core/models/gps_fix.dart';
import '../../providers/ble_providers.dart';
import '../../providers/geocoding_providers.dart';
import '../../providers/gps_providers.dart';
import '../../providers/keep_awake_provider.dart';
import '../../providers/navigation_providers.dart';
import '../../providers/output_providers.dart';
import '../../providers/position_providers.dart';
import '../../providers/routing_providers.dart';
import '../../providers/simulation_providers.dart';
import '../../services/gps/gps_service.dart';
import '../ble/ble_panel.dart';
import '../debug/debug_panel.dart';
import '../route/route_panel.dart';
import '../search/destination_search_bar.dart';
import '../simulation/simulation_panel.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  static const _fallbackCenter = LatLng(48.7, 11.4); // Bayern
  final _controller = MapController();
  bool _follow = true;
  bool _gotFirstFix = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onFix(GpsFix fix) {
    if (!_gotFirstFix) {
      _gotFirstFix = true;
      _controller.move(fix.latLng, 16);
    } else if (_follow) {
      _controller.move(fix.latLng, _controller.camera.zoom);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(appConfigProvider);
    final permission = ref.watch(gpsPermissionProvider);
    final position = ref.watch(positionStreamProvider);
    final fix = position.valueOrNull;
    final destination = ref.watch(destinationSearchProvider).destination;
    final route = ref.watch(routeProvider).valueOrNull;
    final navActive = ref.watch(navigationProvider.select((n) => n.active));
    ref.watch(outputSchedulerProvider); // haelt den Sekundentakt am Laufen
    ref.watch(keepAwakeProvider); // Display an waehrend der Navigation
    ref.watch(bleAutoConnectProvider); // mit gemerktem ESP32 verbinden

    ref.listen<AsyncValue<GpsFix>>(positionStreamProvider, (_, next) {
      final f = next.valueOrNull;
      if (f != null) _onFix(f);
    });

    // Navigation gestartet -> Folgemodus an, nah heranzoomen.
    ref.listen(navigationProvider.select((n) => n.active), (prev, next) {
      if (next && prev != true) {
        setState(() => _follow = true);
        final f = ref.read(positionStreamProvider).valueOrNull;
        if (f != null) _controller.move(f.latLng, 17);
      }
    });

    // Rueckmeldung, wenn die Route waehrend der Fahrt neu berechnet wurde.
    ref.listen(navigationProvider.select((n) => n.reroutes), (prev, next) {
      if (next > (prev ?? 0)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Route neu berechnet')),
        );
      }
    });

    // Neue Route -> Kamera auf die ganze Strecke (nicht waehrend der Fahrt).
    ref.listen(routeProvider.select((r) => r.valueOrNull), (prev, next) {
      if (next != null &&
          next != prev &&
          next.points.length > 1 &&
          !ref.read(navigationProvider).active) {
        setState(() => _follow = false);
        _controller.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(next.points),
            padding: const EdgeInsets.fromLTRB(40, 200, 40, 160),
          ),
        );
      }
    });

    // Neues Ziel gewaehlt -> Kamera dorthin, Folgemodus aus.
    ref.listen(destinationSearchProvider.select((s) => s.destination), (prev, next) {
      if (next != null && next != prev) {
        setState(() => _follow = false);
        _controller.move(next.position, 15);
      }
    });

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _controller,
            options: MapOptions(
              initialCenter: _fallbackCenter,
              initialZoom: 7,
              // Simulation: Langdruck setzt den virtuellen Startpunkt.
              onLongPress: (_, point) {
                if (!ref.read(simulationProvider).enabled ||
                    ref.read(navigationProvider).active) {
                  return;
                }
                ref.read(routeProvider.notifier).clear();
                ref.read(simulationProvider.notifier).setStart(point);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Startpunkt gesetzt')),
                );
              },
              onPositionChanged: (_, hasGesture) {
                // Manuelles Verschieben beendet den Folgemodus.
                if (hasGesture && _follow) setState(() => _follow = false);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.retro_navi',
                maxNativeZoom: 19,
              ),
              if (route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: route.points,
                      strokeWidth: 6,
                      color: Theme.of(context).colorScheme.primary,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                  ],
                ),
              if (fix != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: fix.latLng,
                      width: 44,
                      height: 44,
                      child: _PositionMarker(fix: fix),
                    ),
                  ],
                ),
              if (destination != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: destination.position,
                      width: 44,
                      height: 44,
                      alignment: Alignment.topCenter,
                      child: const Icon(Icons.location_on, color: Colors.red, size: 44),
                    ),
                  ],
                ),
              RichAttributionWidget(
                attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
              ),
            ],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!navActive) ...[
                    const DestinationSearchBar(),
                    const SizedBox(height: 8),
                  ],
                  _StatusCard(
                    permission: permission,
                    position: position,
                    config: config,
                  ),
                  const SimulationPanel(),
                ],
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: RoutePanel(),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const BleStatusButton(),
          const SizedBox(height: 12),
          FloatingActionButton.small(
            heroTag: 'debug',
            tooltip: 'Debug-Ausgabe',
            onPressed: () => showDebugPanel(context),
            child: const Icon(Icons.terminal),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'locate',
            tooltip: 'Auf Standort zentrieren',
            onPressed: fix == null
                ? null
                : () {
                    setState(() => _follow = true);
                    _controller.move(fix.latLng, math.max(_controller.camera.zoom, 16));
                  },
            child: Icon(_follow ? Icons.my_location : Icons.location_searching),
          ),
        ],
      ),
    );
  }
}

class _PositionMarker extends StatelessWidget {
  const _PositionMarker({required this.fix});
  final GpsFix fix;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    final moving = fix.hasHeading && fix.speedMps > 1;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white,
        border: Border.all(color: color, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black26)],
      ),
      child: moving
          ? Transform.rotate(
              angle: fix.heading * math.pi / 180,
              child: Icon(Icons.navigation, color: color, size: 26),
            )
          : Icon(Icons.circle, color: color, size: 14),
    );
  }
}

class _StatusCard extends ConsumerWidget {
  const _StatusCard({
    required this.permission,
    required this.position,
    required this.config,
  });

  final AsyncValue<GpsPermissionStatus> permission;
  final AsyncValue<GpsFix> position;
  final AppConfig config;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gps = ref.read(gpsServiceProvider);

    Widget content;
    final status = permission.valueOrNull;
    final simOn = ref.watch(simulationProvider.select((s) => s.enabled));

    if (simOn) {
      final fix = position.valueOrNull;
      content = fix == null
          ? const _Line(Icons.science, 'Simulation: noch kein Startpunkt')
          : _Line(
              Icons.science,
              'SIM  ${fix.speedKmh.toStringAsFixed(0)} km/h   '
              '${fix.lat.toStringAsFixed(5)}, ${fix.lng.toStringAsFixed(5)}',
            );
    } else if (permission.isLoading) {
      content = const _Line(Icons.hourglass_empty, 'Pruefe Standortfreigabe ...');
    } else if (status == GpsPermissionStatus.serviceDisabled) {
      content = _Line(Icons.location_disabled, 'Ortungsdienste sind aus.',
          action: ('Einstellungen', gps.openLocationSettings), ref: ref);
    } else if (status == GpsPermissionStatus.denied) {
      content = _Line(Icons.lock_outline, 'Standortzugriff verweigert.',
          action: ('Erneut fragen', () async => ref.invalidate(gpsPermissionProvider)),
          ref: ref);
    } else if (status == GpsPermissionStatus.deniedForever) {
      content = _Line(Icons.lock, 'Standortzugriff dauerhaft verweigert.',
          action: ('App-Einstellungen', gps.openAppSettings), ref: ref);
    } else if (permission.hasError) {
      content = _Line(Icons.error_outline, 'Fehler: ${permission.error}');
    } else {
      final fix = position.valueOrNull;
      content = fix == null
          ? const _Line(Icons.gps_not_fixed, 'Warte auf GPS-Fix ...')
          : _Line(
              Icons.gps_fixed,
              '${fix.speedKmh.toStringAsFixed(0)} km/h   '
              '±${fix.accuracy.toStringAsFixed(0)} m   '
              '${fix.lat.toStringAsFixed(5)}, ${fix.lng.toStringAsFixed(5)}',
            );
    }

    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            content,
            Row(
              children: [
                const Icon(Icons.science_outlined, size: 18),
                const SizedBox(width: 8),
                const Expanded(child: Text('Simulation')),
                Switch(
                  value: simOn,
                  onChanged: ref.read(simulationProvider.notifier).setEnabled,
                ),
              ],
            ),
            if (!config.hasOrsKey)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: _Line(Icons.key_off,
                    'Kein ORS-Key (assets/config/secrets.json) - fuer Schritt 1 ok.'),
              ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.icon, this.text, {this.action, this.ref});
  final IconData icon;
  final String text;
  final (String, Future<dynamic> Function())? action;
  final WidgetRef? ref;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyMedium)),
        if (action != null)
          TextButton(onPressed: () => action!.$2(), child: Text(action!.$1)),
      ],
    );
  }
}
