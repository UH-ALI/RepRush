/// App-level navigation state: which tab the shell shows, and a pending
/// "fly the map to this hex" request.
///
/// Providers rather than callbacks threaded through constructors because the
/// screens that change tabs (the post-set summary, the map's train flow) live
/// on routes pushed above the shell, where no shell callback reaches.
///
/// Ownership: C.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ShellTab { map, train, compete, profile }

class ShellTabController extends Notifier<ShellTab> {
  @override
  ShellTab build() => ShellTab.map;

  void go(ShellTab tab) => state = tab;
}

final shellTabProvider = NotifierProvider<ShellTabController, ShellTab>(
  ShellTabController.new,
);

/// A one-shot request for the map to fly to a hex, select it and flash it —
/// set by the summary's "See it on the map", cleared by the map once handled.
class MapFocusController extends Notifier<String?> {
  @override
  String? build() => null;

  void focus(String h3) => state = h3;

  void clear() => state = null;
}

final mapFocusProvider = NotifierProvider<MapFocusController, String?>(
  MapFocusController.new,
);

/// Switches to the map tab and focuses [h3].
void showHexOnMap(WidgetRef ref, String h3) {
  ref.read(shellTabProvider.notifier).go(ShellTab.map);
  ref.read(mapFocusProvider.notifier).focus(h3);
}
