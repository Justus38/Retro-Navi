import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models/gps_fix.dart';
import '../services/gps/gps_service.dart';

final gpsServiceProvider = Provider<GpsService>((ref) => GpsService());

/// Berechtigungsstatus. Mit `ref.invalidate(...)` erneut pruefen.
final gpsPermissionProvider = FutureProvider<GpsPermissionStatus>(
  (ref) => ref.watch(gpsServiceProvider).ensurePermission(),
);

/// Echter GPS-Strom. Spaeter wird ein Provider darueber gelegt, der
/// zwischen GPS und Simulation umschaltet.
final positionStreamProvider = StreamProvider<GpsFix>((ref) async* {
  final status = await ref.watch(gpsPermissionProvider.future);
  if (status != GpsPermissionStatus.granted) return;
  yield* ref.watch(gpsServiceProvider).positionStream();
});
