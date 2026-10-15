import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/models/nav_route.dart';
import '../../providers/geocoding_providers.dart';
import '../../providers/navigation_providers.dart';
import '../../providers/routing_providers.dart';
import '../../services/routing/routing_service.dart';
import '../navigation/navigation_card.dart';
import '../turn_icons.dart';

/// Untere Karte: Ziel, "Route berechnen", Zusammenfassung, Navigation.
class RoutePanel extends ConsumerWidget {
  const RoutePanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final destination = ref.watch(destinationSearchProvider).destination;
    final navActive = ref.watch(navigationProvider.select((n) => n.active));
    if (destination == null) return const SizedBox.shrink();

    final Widget card = navActive
        ? const NavigationCard()
        : _PlanningCard(destinationName: destination.name);

    return SafeArea(
      child: Padding(
        // rechts Platz fuer den Standort-Button
        padding: const EdgeInsets.fromLTRB(12, 0, 84, 12),
        child: card,
      ),
    );
  }
}

class _PlanningCard extends ConsumerWidget {
  const _PlanningCard({required this.destinationName});
  final String destinationName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final route = ref.watch(routeProvider);
    final controller = ref.read(routeProvider.notifier);
    final theme = Theme.of(context);

    Widget body;
    if (route.isLoading) {
      body = const Row(
        children: [
          SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text('Route wird berechnet ...'),
        ],
      );
    } else if (route.hasError) {
      final e = route.error;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            e is RoutingException ? e.message : 'Routenberechnung fehlgeschlagen.',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: controller.calculate,
            icon: const Icon(Icons.refresh),
            label: const Text('Erneut versuchen'),
          ),
        ],
      );
    } else if (route.valueOrNull != null) {
      final r = route.value!;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${formatDistance(r.distanceM)}  •  ${formatDuration(r.durationS)}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: () => _showSteps(context, r),
                icon: const Icon(Icons.list),
                label: Text('${r.steps.length} Schritte'),
              ),
              IconButton(
                tooltip: 'Neu berechnen',
                onPressed: controller.calculate,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: ref.read(navigationProvider.notifier).start,
              icon: const Icon(Icons.navigation),
              label: const Text('Navigation starten'),
            ),
          ),
        ],
      );
    } else {
      body = SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: controller.calculate,
          icon: const Icon(Icons.directions_car),
          label: const Text('Route berechnen'),
        ),
      );
    }

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              destinationName,
              style: theme.textTheme.labelLarge,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            body,
          ],
        ),
      ),
    );
  }

  void _showSteps(BuildContext context, NavRoute route) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, scroll) => ListView.separated(
          controller: scroll,
          itemCount: route.steps.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final s = route.steps[i];
            return ListTile(
              leading: Icon(s.type.icon),
              title: Text(s.instruction),
              subtitle: Text(
                [
                  if (s.streetName.isNotEmpty) s.streetName,
                  formatDistance(s.distanceM),
                ].join('  •  '),
              ),
            );
          },
        ),
      ),
    );
  }
}
