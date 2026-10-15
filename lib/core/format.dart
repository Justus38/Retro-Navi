/// Distanz fuer die Anzeige: "850 m" oder "12,4 km".
String formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(1).replaceAll('.', ',')} km';
}

/// Dauer fuer die Anzeige: "18 min" oder "1 h 12 min".
String formatDuration(double seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${(minutes % 60).toString().padLeft(2, '0')} min';
}
