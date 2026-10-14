import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/models/gps_fix.dart';

enum GpsPermissionStatus { granted, denied, deniedForever, serviceDisabled }

/// Kapselt geolocator. Einzige Stelle im Projekt, die das Paket kennt.
class GpsService {
  Future<GpsPermissionStatus> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return GpsPermissionStatus.serviceDisabled;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    switch (permission) {
      case LocationPermission.denied:
        return GpsPermissionStatus.denied;
      case LocationPermission.deniedForever:
        return GpsPermissionStatus.deniedForever;
      case LocationPermission.whileInUse:
      case LocationPermission.always:
      case LocationPermission.unableToDetermine:
        return GpsPermissionStatus.granted;
    }
  }

  /// Einmalige aktuelle Position (z. B. als Routenstart).
  Future<GpsFix> getCurrent() async {
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    );
    return GpsFix.fromPosition(p);
  }

  /// Laufender Positionsstrom (~1 Hz).
  Stream<GpsFix> positionStream() => Geolocator.getPositionStream(
        locationSettings: _settings(),
      ).map(GpsFix.fromPosition);

  Future<bool> openAppSettings() => Geolocator.openAppSettings();
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  LocationSettings _settings() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
        );
      case TargetPlatform.iOS:
        return AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
        );
      default:
        return const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
        );
    }
  }
}
