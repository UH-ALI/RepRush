/// After switching Live ↔ Demo, a provider whose new load fails still holds
/// the other mode's data in `.value`. `current` and `unlessFailed` must not.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/shared/async_current.dart';

class _Mode extends Notifier<bool> {
  @override
  bool build() => false; // demo

  void goLive() => state = true;
}

final _modeProvider = NotifierProvider<_Mode, bool>(_Mode.new);

/// Demo answers with its hexes; live fails, as `territory/mine` does on a
/// server the route is not deployed to.
final _myHexesProvider = FutureProvider<List<String>>((ref) async {
  if (ref.watch(_modeProvider)) throw StateError('404 territory/mine');
  return ['demo_hex_1', 'demo_hex_2'];
});

void main() {
  test(
    "a failed load in the new mode shows nothing of the old mode's",
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(_myHexesProvider, (_, _) {});

      await container.read(_myHexesProvider.future);
      expect(container.read(_myHexesProvider).current, hasLength(2));

      container.read(_modeProvider.notifier).goLive();
      // While live loads: the demo's list is still the "previous" value…
      final reloading = container.read(_myHexesProvider);
      expect(reloading.isLoading, isTrue);
      expect(reloading.current, isNull);

      await expectLater(
        container.read(_myHexesProvider.future),
        throwsStateError,
      );
      final failed = container.read(_myHexesProvider);
      // …and after the failure Riverpod still offers it as `.value` — the bug.
      expect(failed.value, ['demo_hex_1', 'demo_hex_2']);
      expect(failed.current, isNull);
      expect(failed.unlessFailed, isNull);
    },
  );

  test('a quiet reload keeps showing the value with unlessFailed', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.listen(_myHexesProvider, (_, _) {});
    await container.read(_myHexesProvider.future);

    container.invalidate(_myHexesProvider);
    final polling = container.read(_myHexesProvider);
    expect(polling.unlessFailed, hasLength(2));
  });
}
