import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/ble_providers.dart';
import '../../services/ble/ble_models.dart';

void showBlePanel(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const BlePanel(),
  );
}

/// Kleiner Knopf auf der Karte; Farbe und Symbol zeigen den Verbindungsstatus.
class BleStatusButton extends ConsumerWidget {
  const BleStatusButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status =
        ref.watch(bleLinkProvider.select((l) => l.valueOrNull?.status)) ??
            BleStatus.idle;
    final connected = status == BleStatus.connected;
    final icon = switch (status) {
      BleStatus.connected => Icons.bluetooth_connected,
      BleStatus.connecting || BleStatus.reconnecting => Icons.bluetooth_searching,
      BleStatus.idle => Icons.bluetooth,
    };
    return FloatingActionButton.small(
      heroTag: 'ble',
      tooltip: 'Bluetooth (ESP32)',
      backgroundColor: connected ? Colors.green.shade700 : null,
      foregroundColor: connected ? Colors.white : null,
      onPressed: () => showBlePanel(context),
      child: Icon(icon),
    );
  }
}

class BlePanel extends ConsumerStatefulWidget {
  const BlePanel({super.key});

  @override
  ConsumerState<BlePanel> createState() => _BlePanelState();
}

class _BlePanelState extends ConsumerState<BlePanel> {
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    // Beim Oeffnen ohne Verbindung gleich suchen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final status = ref.read(bleLinkProvider).valueOrNull?.status;
      if (status == null || status == BleStatus.idle) {
        ref.read(bleControllerProvider).scan();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final link = ref.watch(bleLinkProvider).valueOrNull ?? const BleLinkState();
    final scanning = ref.watch(bleScanningProvider).valueOrNull ?? false;
    final adapterOn = ref.watch(bleAdapterOnProvider).valueOrNull;
    final results = ref.watch(bleScanResultsProvider).valueOrNull ?? const <BleDevice>[];
    final message = ref.watch(bleMessageProvider);
    final ctrl = ref.read(bleControllerProvider);
    final theme = Theme.of(context);

    final busy = link.status != BleStatus.idle;
    final shown =
        _showAll ? results : results.where((d) => d.isRetroNavi).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Bluetooth (ESP32)', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _StatusRow(link: link),
          if (link.error != null && link.status == BleStatus.reconnecting)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(link.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ),
          if (adapterOn == false)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Bluetooth ist ausgeschaltet. Bitte am Handy einschalten.',
                  style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message, style: TextStyle(color: theme.colorScheme.error)),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!busy)
                FilledButton.icon(
                  onPressed: scanning || adapterOn == false ? null : ctrl.scan,
                  icon: scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(scanning ? 'Suche läuft ...' : 'Suchen'),
                ),
              if (busy)
                FilledButton.tonalIcon(
                  onPressed: ctrl.disconnect,
                  icon: const Icon(Icons.link_off),
                  label: const Text('Trennen'),
                ),
              if (busy || link.deviceId != null)
                TextButton.icon(
                  onPressed: ctrl.forget,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Gerät vergessen'),
                ),
            ],
          ),
          if (!busy) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Alle Geräte zeigen'),
              subtitle: const Text('Hilft, falls der ESP32 nicht erscheint'),
              value: _showAll,
              onChanged: (v) => setState(() => _showAll = v),
            ),
            const Divider(height: 8),
            if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  scanning
                      ? 'Suche ...'
                      : 'Nichts gefunden. ESP32 eingeschaltet und Sketch gestartet? '
                          'Sonst "Alle Geräte zeigen" probieren.',
                  style: theme.textTheme.bodySmall,
                ),
              )
            else
              for (final d in shown)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(d.isRetroNavi ? Icons.memory : Icons.bluetooth),
                  title: Text(d.name.isEmpty ? '(ohne Namen)' : d.name),
                  subtitle: Text('${d.id}   ${d.rssi} dBm'),
                  onTap: () => ctrl.connect(d),
                ),
          ],
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.link});
  final BleLinkState link;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (link.status) {
      BleStatus.idle => (Icons.bluetooth_disabled, 'Nicht verbunden'),
      BleStatus.connecting => (Icons.bluetooth_searching, 'Verbinde mit ${link.label} ...'),
      BleStatus.connected => (
          Icons.bluetooth_connected,
          'Verbunden mit ${link.label}'
              '${link.mtu != null ? ' (MTU ${link.mtu})' : ''}'
        ),
      BleStatus.reconnecting => (
          Icons.bluetooth_searching,
          'Verbindung weg, neuer Versuch'
              '${link.attempt > 0 ? ' (#${link.attempt})' : ''} ...'
        ),
    };
    return Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    );
  }
}
