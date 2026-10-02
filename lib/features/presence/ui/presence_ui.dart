/// Nearby players on the map: the opt-in sheet, the player markers' sheet,
/// and the profile switch.
///
/// The copy makes the privacy shape explicit every time the switch is in
/// front of the athlete — only your hex is shared, only while you choose.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/features/challenges/ui/duel_widgets.dart';
import 'package:reprush/features/presence/data/presence_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/widgets/widgets.dart';

/// The colour other athletes wear on the map — distinct from rival hexes
/// (red) and spots (violet).
const Color playerColor = RepRushTokens.electricMagenta;

/// A round initial for another athlete.
class PlayerAvatar extends StatelessWidget {
  const PlayerAvatar({super.key, required this.handle, this.size = 40});

  final String handle;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: playerColor,
      shape: BoxShape.circle,
      border: Border.all(color: Colors.white, width: 2),
      boxShadow: RepRushTokens.cardShadow,
    ),
    child: Text(
      handle.isEmpty ? '?' : handle.characters.first.toUpperCase(),
      style: TextStyle(
        fontFamily: RepRushTokens.displayFont,
        fontWeight: FontWeight.w800,
        fontSize: size * .45,
        color: Colors.white,
      ),
    ),
  );
}

const _privacyLines = [
  (
    Icons.hexagon_outlined,
    'Others see which hex you\'re in — never your '
        'exact spot.',
  ),
  (
    Icons.sports_kabaddi,
    'Anyone visible nearby can challenge you to a duel, '
        'and you can challenge them.',
  ),
  (
    Icons.visibility_off_outlined,
    'Turn it off any time and you disappear '
        'straight away.',
  ),
];

/// Opt in (or out) of being seen. While visible it also lists who is around,
/// so it doubles as the "find someone to duel" list.
Future<void> showVisibilitySheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      isScrollControlled: true,
      builder: (_) => const _VisibilitySheet(),
    );

class _VisibilitySheet extends ConsumerWidget {
  const _VisibilitySheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(presenceVisibleProvider).value ?? false;
    final players = ref.watch(nearbyPlayersProvider).value ?? const [];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  visible ? Icons.visibility : Icons.visibility_off_outlined,
                  color: visible ? playerColor : Colors.white70,
                ),
                const SizedBox(width: RepRushTokens.spaceSm),
                Expanded(
                  child: Text(
                    visible
                        ? "You're visible nearby"
                        : 'Play with people nearby',
                    style: RepRushTokens.sectionTitle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: RepRushTokens.spaceMd),
            if (!visible)
              for (final (icon, line) in _privacyLines)
                Padding(
                  padding: const EdgeInsets.only(bottom: RepRushTokens.spaceSm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(icon, size: 20, color: playerColor),
                      const SizedBox(width: RepRushTokens.spaceSm + 4),
                      Expanded(child: Text(line)),
                    ],
                  ),
                )
            else if (players.isEmpty)
              Text(
                'Nobody else is visible around you yet. Stay visible and '
                "they'll show up on your map.",
                style: RepRushTokens.bodyLabel,
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final player in players) PlayerRow(player: player),
                  ],
                ),
              ),
            const SizedBox(height: RepRushTokens.spaceMd),
            if (visible)
              OutlinedButton.icon(
                onPressed: () {
                  ref.read(presenceVisibleProvider.notifier).setVisible(false);
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.visibility_off_outlined),
                label: const Text('Go hidden'),
              )
            else
              BrandButton(
                label: 'Go visible',
                icon: Icons.visibility,
                onPressed: () =>
                    ref.read(presenceVisibleProvider.notifier).setVisible(true),
              ),
          ],
        ),
      ),
    );
  }
}

/// The athletes standing in one hex — usually one, sometimes a crowd.
Future<void> showPlayersSheet(
  BuildContext context,
  List<NearbyPlayer> players,
) => showModalBottomSheet<void>(
  context: context,
  backgroundColor: RepRushTokens.surfaceDark,
  isScrollControlled: true,
  builder: (_) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(RepRushTokens.spaceLg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            players.length == 1
                ? 'Training nearby'
                : '${players.length} athletes in this hex',
            style: RepRushTokens.sectionTitle,
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          for (final player in players) PlayerRow(player: player),
        ],
      ),
    ),
  ),
);

/// Avatar, name, level, how far, and the Challenge button.
class PlayerRow extends ConsumerWidget {
  const PlayerRow({super.key, required this.player});

  final NearbyPlayer player;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final here = ref.watch(hereProvider);
    final away = here == null
        ? null
        : formatDistance(
            distanceM(here.lat, here.lng, player.centre.lat, player.centre.lng),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: RepRushTokens.spaceSm),
      child: Row(
        children: [
          PlayerAvatar(handle: player.handle),
          const SizedBox(width: RepRushTokens.spaceSm + 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  player.handle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  [
                    'Level ${player.level}',
                    '${player.hexesHeld} '
                        '${player.hexesHeld == 1 ? 'hex' : 'hexes'}',
                    if (away != null) '~$away away',
                  ].join(' · '),
                  style: RepRushTokens.bodyLabel,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: RepRushTokens.spaceSm),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: playerColor),
            onPressed: () => showChallengeSheet(context, player),
            icon: const Icon(Icons.sports_kabaddi, size: 18),
            label: const Text('Duel'),
          ),
        ],
      ),
    );
  }
}

/// The Profile switch — the same opt-in as the map pill.
class VisibilityCard extends ConsumerWidget {
  const VisibilityCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(presenceVisibleProvider).value ?? false;
    return GlassCard(
      padding: const EdgeInsets.symmetric(
        horizontal: RepRushTokens.spaceSm,
        vertical: RepRushTokens.spaceXs,
      ),
      // Its own Material so the tile's splash shows above the card fill.
      child: Material(
        type: MaterialType.transparency,
        child: SwitchListTile(
          value: visible,
          activeThumbColor: playerColor,
          onChanged: (value) =>
              ref.read(presenceVisibleProvider.notifier).setVisible(value),
          secondary: Icon(
            visible ? Icons.visibility : Icons.visibility_off_outlined,
            color: visible ? playerColor : Colors.white70,
          ),
          title: const Text(
            'Visible to nearby players',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            'Shows which hex you\'re in — never your exact spot — so you can '
            'duel people nearby.',
            style: RepRushTokens.bodyLabel,
          ),
        ),
      ),
    );
  }
}
