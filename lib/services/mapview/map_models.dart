/// Datenmodelle fuer die Kartenansicht auf dem ESP32-Display.
///
/// Prinzip: Die App schickt selten einen "Chunk" (die Strecke voraus als
/// Linienzug in Metern, in einem lokalen Koordinatensystem) und jede Sekunde
/// eine "Pose" (Fahrzeugposition und Fahrtrichtung im gleichen System).
/// Drehen, Verschieben und Skalieren macht der ESP32.
library;

import 'local_frame.dart';

/// Ein Kartenstueck. Koordinaten: x = Meter nach Osten, y = Meter nach Norden,
/// bezogen auf einen beliebigen Ursprung, den nur die App kennt.
class MapChunk {
  const MapChunk({
    required this.id,
    required this.route,
    required this.routeEnd,
    this.frameId = 0,
  });

  /// Kennung des Koordinatensystems. Strassen (Nebenstrassen) gelten nur fuer
  /// Chunks mit gleicher Rahmen-Kennung. 0 = unbekannt/keine Strassen.
  final int frameId;

  /// Kennung. Eine Pose gehoert nur zum Chunk mit gleicher Kennung.
  final int id;

  /// Streckenpunkte flach: x0, y0, x1, y1, ... (ganze Meter).
  final List<int> route;

  /// true, wenn der letzte Punkt das Ziel der Route ist.
  final bool routeEnd;

  int get pointCount => route.length ~/ 2;
}

/// Fahrzeugzustand im Koordinatensystem eines Chunks.
class MapPose {
  const MapPose({
    required this.chunkId,
    required this.x,
    required this.y,
    required this.headingDeg,
    required this.zoomM,
    required this.nextIndex,
  });

  final int chunkId;
  final double x;
  final double y;

  /// Fahrtrichtung, 0 = Norden, im Uhrzeigersinn, 0..359.
  final int headingDeg;

  /// Sichtweite nach vorn in Metern (Fahrzeug bis oberer Bildrand).
  final int zoomM;

  /// Index des ersten Chunk-Punkts VOR dem Fahrzeug. Alles davor ist schon
  /// gefahren und wird gedimmt gezeichnet.
  final int nextIndex;
}

/// Ergebnis eines Aufbau-Schritts: immer eine Pose, ab und zu auch ein Chunk.
class MapUpdate {
  const MapUpdate({this.chunk, required this.pose, this.window});

  /// Nur gesetzt, wenn der Chunk (neu) gesendet werden soll.
  final MapChunk? chunk;
  final MapPose pose;

  /// Routenabschnitt in voller Aufloesung, fuer die Nebenstrassen-Auswahl.
  final MapWindow? window;
}

/// Der Routenabschnitt um das Fahrzeug im Koordinatensystem [frame].
class MapWindow {
  const MapWindow({
    required this.frame,
    required this.frameId,
    required this.chunkId,
    required this.xs,
    required this.ys,
    required this.alongs,
    required this.vehicleAlong,
  });

  final LocalFrame frame;
  final int frameId;

  /// Kennung des zugehoerigen Chunks (aendert sich bei neuer Route).
  final int chunkId;
  final List<double> xs;
  final List<double> ys;

  /// Streckenmeter jedes Punkts.
  final List<double> alongs;
  final double vehicleAlong;
}
