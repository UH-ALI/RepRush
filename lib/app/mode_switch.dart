/// Live or demo, chosen in the app: the Profile card that switches it, and the
/// badge that says you are in the demo so nobody mistakes it for the real map.
///
/// Ownership: C.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/shared/widgets/widgets.dart';

class AppModeCard extends ConsumerWidget {
  const AppModeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(appModeProvider);
    final canGoLive = ref.watch(backendConfigProvider).canGoLive;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.public, color: RepRushTokens.brand),
              SizedBox(width: RepRushTokens.spaceSm + 4),
              Text('Game world', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          SegmentedButton<ApiMode>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: ApiMode.live,
                enabled: canGoLive,
                icon: const Icon(Icons.wifi_tethering),
                label: const Text('Live'),
              ),
              const ButtonSegment(
                value: ApiMode.stub,
                icon: Icon(Icons.play_circle_outline),
                label: Text('Demo'),
              ),
            ],
            selected: {mode},
            onSelectionChanged: (selected) =>
                _switch(context, ref, selected.single),
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          Text(
            mode == ApiMode.live
                ? 'Real territory, and real players training near you.'
                : canGoLive
                ? 'The real map and leaderboard. Your sets, the players nearby '
                      'and your duels are simulated, and hexes you capture '
                      'show only on this phone. Your real score is never '
                      'touched.'
                : 'A practice world around you, with scripted rivals to '
                      'duel. Nothing here touches real territory.',
            style: RepRushTokens.bodyLabel,
          ),
          if (!canGoLive) ...[
            const SizedBox(height: RepRushTokens.spaceXs),
            Text(
              "This build isn't connected to a server, so only the demo is "
              'available.',
              style: RepRushTokens.bodyLabel,
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _switch(
    BuildContext context,
    WidgetRef ref,
    ApiMode mode,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(appModeProvider.notifier).select(mode);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          mode == ApiMode.live
              ? 'Switched to the live game.'
              : 'Switched to the demo world.',
        ),
      ),
    );
  }
}

/// A small "DEMO" tag for the map's app bar — nothing at all in live mode.
class DemoBadge extends ConsumerWidget {
  const DemoBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(isLiveProvider)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: RepRushTokens.spaceMd),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: RepRushTokens.feedbackAmber.withValues(alpha: .16),
          borderRadius: BorderRadius.circular(99),
          border: Border.all(
            color: RepRushTokens.feedbackAmber.withValues(alpha: .7),
          ),
        ),
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Text(
            'DEMO',
            style: TextStyle(
              fontFamily: RepRushTokens.displayFont,
              color: RepRushTokens.feedbackAmber,
              fontWeight: FontWeight.w800,
              letterSpacing: .8,
            ),
          ),
        ),
      ),
    );
  }
}
