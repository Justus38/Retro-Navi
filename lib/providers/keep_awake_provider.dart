import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'navigation_providers.dart';

/// Haelt das Display waehrend der Navigation an. Wird im MapScreen beobachtet.
final keepAwakeProvider = Provider<void>((ref) {
  final active = ref.watch(navigationProvider.select((n) => n.active));
  if (active) {
    WakelockPlus.enable();
  } else {
    WakelockPlus.disable();
  }
  ref.onDispose(WakelockPlus.disable);
});
