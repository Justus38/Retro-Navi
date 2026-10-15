import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models/nav_route.dart';
import '../../providers/navigation_providers.dart';
import '../turn_icons.dart';

/// Anzeige waehrend der Navigation (Vorschau dessen, was das Retro-Navi zeigt).
class NavigationCard extends ConsumerWidget {
  const NavigationCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nav = ref.watch(navigationProvider);
    final theme = Theme.of(context);

    final title = nav.arrived ? 'Ziel erreicht' : formatDistance(nav.distToTurnM);
    final subtitle = nav.arrived
        ? ''
        : [
            if (nav.street.isNotEmpty) nav.street,
            if (nav.turn == TurnType.enterRoundabout && nav.exitNumber != null)
              '${nav.exitNumber}. Ausfahrt',
          ].join('  •  ');

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(nav.turn.icon, size: 48),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: theme.textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      if (subtitle.isNotEmpty)
                        Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
              ],
            ),
            if (nav.rerouting || nav.offRoute)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                    const SizedBox(width: 8),
                    Text(nav.rerouting ? 'Route wird neu berechnet ...' : 'Abseits der Route ...'),
                  ],
                ),
              ),
            if (nav.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(nav.error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            const Divider(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Metric('Rest', formatDistance(nav.remainingM)),
                _Metric('Zeit', formatDuration(nav.remainingS)),
                _Metric('Tempo', '${nav.speedKmh.round()} km/h'),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: ref.read(navigationProvider.notifier).stop,
                icon: const Icon(Icons.stop),
                label: const Text('Navigation beenden'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Column(
      children: [
        Text(value, style: t.titleMedium),
        Text(label, style: t.bodySmall),
      ],
    );
  }
}
