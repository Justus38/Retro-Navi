import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/navigation_providers.dart';
import '../../providers/simulation_providers.dart';

/// Bedienfeld der Simulation (nur sichtbar, wenn sie eingeschaltet ist).
class SimulationPanel extends ConsumerWidget {
  const SimulationPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sim = ref.watch(simulationProvider);
    if (!sim.enabled) return const SizedBox.shrink();

    final ctrl = ref.read(simulationProvider.notifier);
    final navActive = ref.watch(navigationProvider.select((n) => n.active));
    final theme = Theme.of(context);

    String? hint;
    if (!sim.hasPosition) {
      hint = 'Kein Startpunkt: Karte lange drücken, um ihn zu setzen.';
    } else if (!sim.hasRoute) {
      hint = 'Ziel wählen und Route berechnen. Langer Druck auf die Karte setzt den Startpunkt.';
    } else if (!navActive) {
      hint = 'Play startet die Navigation. "Abweichen" testet die Neuberechnung und geht nur bei laufender Navigation.';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Card(
        elevation: 3,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.science, size: 18),
                  const SizedBox(width: 8),
                  Text('Simulation', style: theme.textTheme.titleSmall),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Von vorn',
                    onPressed: sim.hasRoute ? ctrl.restart : null,
                    icon: const Icon(Icons.replay),
                  ),
                  IconButton.filled(
                    tooltip: sim.playing ? 'Pause' : 'Start',
                    onPressed: !sim.hasRoute
                        ? null
                        : () {
                            if (sim.playing) {
                              ctrl.pause();
                            } else if (!navActive) {
                              // Fahrt ohne Navigation ergibt keinen Sinn.
                              ref.read(navigationProvider.notifier).start();
                            } else {
                              ctrl.play();
                            }
                          },
                    icon: Icon(sim.playing ? Icons.pause : Icons.play_arrow),
                  ),
                ],
              ),
              Row(
                children: [
                  SizedBox(
                    width: 76,
                    child: Text('${sim.speedKmh.round()} km/h'),
                  ),
                  Expanded(
                    child: Slider(
                      min: 5,
                      max: 200,
                      divisions: 39,
                      value: math.max(5.0, math.min(200.0, sim.speedKmh)),
                      onChanged: ctrl.setSpeed,
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: sim.hasRoute && navActive ? ctrl.toggleOffRoute : null,
                  icon: Icon(sim.offRoute ? Icons.undo : Icons.call_split),
                  label: Text(sim.offRoute ? 'Zurück auf die Route' : 'Abweichen (100 m)'),
                ),
              ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(hint, style: theme.textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
