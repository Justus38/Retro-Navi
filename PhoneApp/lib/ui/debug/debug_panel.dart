import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/navigation_providers.dart';
import '../../providers/output_providers.dart';

void showDebugPanel(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const DebugPanel(),
  );
}

/// Zeigt, was an den ESP32 gesendet wird (und spaeter gesendet wuerde).
class DebugPanel extends ConsumerWidget {
  const DebugPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final log = ref.watch(debugLogProvider);
    final navActive = ref.watch(navigationProvider.select((n) => n.active));
    final theme = Theme.of(context);
    final payload = log.lastPayload;
    const mono = TextStyle(fontFamily: 'monospace');

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Debug-Ausgabe', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            navActive
                ? 'Navigation läuft: Es wird jede Sekunde gesendet.'
                : 'Inaktiv: Gesendet wird nur bei laufender Navigation.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              payload ?? '-',
              style: mono.copyWith(fontSize: 15),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            payload == null
                ? 'Noch nichts gesendet'
                : '${utf8.encode(payload).length} Bytes  •  ${log.sentCount} gesendet',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonalIcon(
                onPressed: payload == null
                    ? null
                    : () {
                        Clipboard.setData(ClipboardData(text: payload));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('JSON kopiert')),
                        );
                      },
                icon: const Icon(Icons.copy),
                label: const Text('Kopieren'),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: log.entries.isEmpty
                    ? null
                    : ref.read(debugLogProvider.notifier).clear,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Log leeren'),
              ),
            ],
          ),
          const Divider(height: 24),
          Text('Verlauf (letzte ${DebugLogController.maxEntries})',
              style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          if (log.entries.isEmpty)
            Text('Keine Einträge.', style: theme.textTheme.bodySmall)
          else
            for (final e in log.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${_time(e.time)}  ${e.text}',
                  style: mono.copyWith(
                    fontSize: 12,
                    color: e.isError ? theme.colorScheme.error : null,
                  ),
                ),
              ),
        ],
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
  static String _time(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}
