import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../providers/geocoding_providers.dart';

class DestinationSearchBar extends ConsumerStatefulWidget {
  const DestinationSearchBar({super.key});

  @override
  ConsumerState<DestinationSearchBar> createState() => _DestinationSearchBarState();
}

class _DestinationSearchBarState extends ConsumerState<DestinationSearchBar> {
  final _text = TextEditingController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(destinationSearchProvider);
    final hasOrsKey = ref.watch(appConfigProvider).hasOrsKey;
    final ctrl = ref.read(destinationSearchProvider.notifier);

    final showClear = s.query.isNotEmpty || s.destination != null;
    final noResults = s.destination == null &&
        !s.loading &&
        s.error == null &&
        s.suggestions.isEmpty &&
        s.query.length >= 3;

    return Card(
      elevation: 3,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _text,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            onChanged: ctrl.onQueryChanged,
            onSubmitted: (_) => ctrl.submit(),
            decoration: InputDecoration(
              hintText: 'Ziel eingeben',
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: s.loading
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : showClear
                      ? IconButton(
                          tooltip: 'Ziel löschen',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _text.clear();
                            ctrl.clear();
                          },
                        )
                      : null,
            ),
          ),
          if (s.error != null)
            _InfoRow(Icons.error_outline, s.error!)
          else if (noResults)
            _InfoRow(
              Icons.info_outline,
              hasOrsKey
                  ? 'Keine Treffer.'
                  : 'Ohne ORS-Key keine Vorschläge: Suche mit der Such-Taste starten.',
            ),
          if (s.destination == null && s.suggestions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: s.suggestions.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final p = s.suggestions[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined),
                    title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: p.label == p.name
                        ? null
                        : Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: () {
                      _text.text = p.label;
                      _focus.unfocus();
                      ctrl.select(p);
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      );
}
