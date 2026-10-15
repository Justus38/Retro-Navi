import 'dart:async';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../../core/geo.dart';
import '../../core/models/gps_fix.dart';
import '../../core/models/nav_route.dart';
import 'route_playback.dart';

/// Erzeugt virtuelle GPS-Fixes (1 Hz) entlang der Route.
/// Liefert denselben Typ [GpsFix] wie der echte GpsService.
class SimulationService {
  static const lateralOffsetM = 100.0;

  final _controller = StreamController<GpsFix>.broadcast();

  RoutePlayback? _playback;
  GpsFix? _current;
  Timer? _timer;
  DateTime? _lastTick;
  bool _playing = false;
  double _speedKmh = 50;
  double _offsetM = 0;

  /// Wird aufgerufen, wenn das Streckenende erreicht ist.
  void Function()? onFinished;

  Stream<GpsFix> get stream => _controller.stream;
  GpsFix? get current => _current;
  bool get playing => _playing;
  double get speedKmh => _speedKmh;
  bool get hasRoute => _playback != null;
  bool get lateralOffsetActive => _offsetM != 0;

  /// Timer starten (beim Einschalten der Simulation).
  void start() {
    if (_timer != null) return;
    _lastTick = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final dt = math.min(2.0, now.difference(_lastTick!).inMilliseconds / 1000.0);
      _lastTick = now;
      tick(dt);
    });
    _emitCurrent();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _playing = false;
  }

  /// Ein Zeitschritt von [dtSeconds] Sekunden.
  void tick(double dtSeconds) {
    final pb = _playback;
    if (pb != null && _playing) {
      pb.advance(_speedKmh / 3.6 * dtSeconds);
      if (pb.finished) {
        _playing = false;
        _publish(pb.position, pb.heading, 0);
        onFinished?.call();
        return;
      }
    }
    _emitCurrent();
  }

  /// Stellt das Fahrzeug ohne Route an einen Punkt (Startpunkt setzen).
  void parkAt(LatLng position, {double heading = 0}) {
    _playback = null;
    _playing = false;
    _offsetM = 0;
    _publish(position, heading, 0, applyOffset: false);
  }

  /// Neue Route laden (auch bei Neuberechnung waehrend der Fahrt):
  /// Fahrt beginnt am Routenanfang, "Spielzustand" bleibt erhalten.
  void loadRoute(NavRoute? route) {
    if (route == null || route.points.length < 2) {
      _playback = null;
      _playing = false;
      _offsetM = 0;
      return;
    }
    _playback = RoutePlayback(route.points);
    _offsetM = 0;
    if (_timer != null) _emitCurrent();
  }

  void play() {
    final pb = _playback;
    if (pb == null) return;
    if (pb.finished) pb.reset();
    _playing = true;
  }

  void pause() => _playing = false;

  void restart() {
    _playback?.reset();
    _offsetM = 0;
    _emitCurrent();
  }

  void setSpeed(double kmh) => _speedKmh = math.max(0.0, kmh);

  /// Versetzt die virtuelle Position seitlich von der Route (Test der
  /// Neuberechnung). Erneuter Aufruf nimmt den Versatz zurueck.
  void toggleLateralOffset() {
    if (_playback == null) return;
    _offsetM = _offsetM == 0 ? lateralOffsetM : 0;
    _emitCurrent();
  }

  void _emitCurrent() {
    final pb = _playback;
    if (pb != null) {
      _publish(pb.position, pb.heading, _playing ? _speedKmh / 3.6 : 0);
    } else {
      final c = _current;
      if (c != null) _publish(c.latLng, c.heading, 0, applyOffset: false);
    }
  }

  void _publish(LatLng pos, double heading, double speedMps,
      {bool applyOffset = true}) {
    var p = pos;
    if (applyOffset && _offsetM != 0) {
      p = offsetPoint(pos, heading + 90, _offsetM); // rechts neben der Route
    }
    final fix = GpsFix(
      lat: p.latitude,
      lng: p.longitude,
      speedMps: speedMps,
      heading: heading,
      accuracy: 5,
      timestamp: DateTime.now(),
    );
    _current = fix;
    if (!_controller.isClosed) _controller.add(fix);
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
