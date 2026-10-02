/// Duels on screen: the challenge sheet, the one card every duel state is
/// drawn with, the map banner and the Compete section.
///
/// One set each, same exercise, most verified reps wins. Every number on a
/// card is the server's — the HUD's count never decides a duel.
///
/// Ownership: C (ui).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/challenges/data/duels_providers.dart';
import 'package:reprush/features/presence/ui/presence_ui.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/ui/training_flow.dart';
import 'package:reprush/models/models.dart';
import 'package:reprush/shared/async_current.dart';
import 'package:reprush/shared/errors.dart';
import 'package:reprush/shared/widgets/widgets.dart';

/// Pick an exercise and send [player] a challenge.
Future<void> showChallengeSheet(BuildContext context, NearbyPlayer player) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: RepRushTokens.surfaceDark,
      isScrollControlled: true,
      builder: (_) => _ChallengeSheet(player: player),
    );

class _ChallengeSheet extends ConsumerStatefulWidget {
  const _ChallengeSheet({required this.player});

  final NearbyPlayer player;

  @override
  ConsumerState<_ChallengeSheet> createState() => _ChallengeSheetState();
}

class _ChallengeSheetState extends ConsumerState<_ChallengeSheet> {
  late String _movementId = ref.read(selectedMovementProvider);
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final movements = ref.watch(movementsProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PlayerAvatar(handle: widget.player.handle, size: 36),
                const SizedBox(width: RepRushTokens.spaceSm + 4),
                Expanded(
                  child: Text(
                    'Duel ${widget.player.handle}',
                    style: RepRushTokens.sectionTitle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: RepRushTokens.spaceXs),
            Text(
              'One set each, most reps wins. Once they accept you both have '
              '10 minutes. Winner takes +100 XP.',
              style: RepRushTokens.bodyLabel,
            ),
            const SizedBox(height: RepRushTokens.spaceMd),
            ...switch (movements) {
              AsyncData(:final value) => [
                for (final movement in captureReadyMovements(value)) ...[
                  MovementTile(
                    movement: movement,
                    selected: movement.id == _movementId,
                    onTap: () => setState(() => _movementId = movement.id),
                  ),
                  const SizedBox(height: RepRushTokens.spaceSm),
                ],
              ],
              AsyncError(:final error) => [Text(describeError(error))],
              _ => const [
                Padding(
                  padding: EdgeInsets.all(RepRushTokens.spaceMd),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            },
            const SizedBox(height: RepRushTokens.spaceSm),
            BrandButton(
              label: 'Challenge to ${movementPlural(_movementId)}',
              icon: Icons.sports_kabaddi,
              loading: _sending,
              onPressed: _send,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _sending = true);
    try {
      await ref
          .read(duelsProvider.notifier)
          .challenge(opponentId: widget.player.userId, movementId: _movementId);
      // The sheet and, beneath it, the player sheet both close: the duel card
      // on the map takes over from here.
      navigator.popUntil((route) => route.isFirst);
      messenger.showSnackBar(
        SnackBar(content: Text('Challenge sent to ${widget.player.handle}')),
      );
    } catch (error) {
      if (mounted) setState(() => _sending = false);
      messenger.showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

/// The duel worth showing on the map right now, or null: a challenge to
/// answer first, then a reward to claim, then a duel in progress.
Duel? headlineDuel(List<Duel> duels) {
  int priority(Duel d) => d.incoming && d.status == DuelStatus.pending
      ? 0
      : d.canClaim
      ? 1
      : d.status == DuelStatus.active
      ? 2
      : d.status == DuelStatus.pending
      ? 3
      : 9;
  final ranked = [...duels.where((d) => priority(d) < 9)]
    ..sort((a, b) => priority(a).compareTo(priority(b)));
  return ranked.firstOrNull;
}

/// The map's duel strip — nothing at all when there is no duel to show.
class MapDuelBanner extends ConsumerWidget {
  const MapDuelBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duels = ref.watch(duelsProvider).unlessFailed ?? const [];
    final duel = headlineDuel(duels);
    if (duel == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: RepRushTokens.spaceSm),
      child: DuelCard(duel: duel),
    );
  }
}

/// Every duel on Compete, newest first.
class DuelsSection extends ConsumerWidget {
  const DuelsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duels = ref.watch(duelsProvider).unlessFailed ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Duels', style: RepRushTokens.sectionTitle),
        const SizedBox(height: RepRushTokens.spaceSm),
        if (duels.isEmpty)
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Go visible to see who is training near you, then '
                  'challenge them: one set each, most reps wins.',
                ),
                const SizedBox(height: RepRushTokens.spaceSm),
                OutlinedButton.icon(
                  onPressed: () => showVisibilitySheet(context),
                  icon: const Icon(Icons.people_alt_outlined),
                  label: const Text('Find players nearby'),
                ),
              ],
            ),
          )
        else
          for (final duel in duels.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: RepRushTokens.spaceSm),
              child: DuelCard(duel: duel),
            ),
      ],
    );
  }
}

/// The newest duel this set counts toward, for the post-set summary.
class SetDuelCard extends ConsumerWidget {
  const SetDuelCard({super.key, required this.movementId});

  final String? movementId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final duels = ref.watch(duelsProvider).unlessFailed ?? const [];
    final duel = duels
        .where(
          (d) =>
              d.movementId == movementId &&
              (d.status == DuelStatus.active || d.canClaim),
        )
        .firstOrNull;
    if (duel == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: RepRushTokens.spaceMd),
      child: DuelCard(duel: duel),
    );
  }
}

/// One duel, in whatever state it is in, with the one action that state
/// allows.
class DuelCard extends ConsumerStatefulWidget {
  const DuelCard({super.key, required this.duel});

  final Duel duel;

  @override
  ConsumerState<DuelCard> createState() => _DuelCardState();
}

class _DuelCardState extends ConsumerState<DuelCard> {
  bool _busy = false;

  Duel get duel => widget.duel;

  @override
  Widget build(BuildContext context) {
    final them = duel.opponentHandle;
    final exercise = movementPlural(duel.movementId);
    final (String title, String subtitle) = switch (duel.status) {
      DuelStatus.pending when duel.incoming => (
        '$them challenged you',
        'Most $exercise in one set. Accept to start a 10-minute window.',
      ),
      DuelStatus.pending => (
        'Waiting for $them…',
        'You challenged them to $exercise.',
      ),
      DuelStatus.active => (
        'Duel vs $them',
        duel.myReps == null
            ? 'One set of $exercise — make it count.'
            : 'Your set is in. Waiting for $them.',
      ),
      DuelStatus.finished => (
        switch (duel.result) {
          'won' => 'You beat $them!',
          'lost' => '$them won this one',
          _ => 'Dead heat with $them',
        },
        duel.myReps == null
            ? "You didn't post a set in time."
            : duel.claimed
            ? 'Reward claimed.'
            : 'Claim your reward.',
      ),
      DuelStatus.declined => ('$them passed', 'Challenge declined.'),
      DuelStatus.expired => (
        duel.incoming ? "You missed $them's challenge" : '$them never answered',
        'The challenge lapsed.',
      ),
    };

    final showScore =
        duel.status == DuelStatus.active || duel.status == DuelStatus.finished;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: RepRushTokens.chrome,
        borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
        border: Border.all(
          color: playerColor.withValues(alpha: duel.open ? .6 : .25),
        ),
        boxShadow: RepRushTokens.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceSm + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                PlayerAvatar(handle: them, size: 34),
                const SizedBox(width: RepRushTokens.spaceSm + 2),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      Text(subtitle, style: RepRushTokens.bodyLabel),
                    ],
                  ),
                ),
                if (duel.status == DuelStatus.active && duel.endsAtMs != null)
                  _Countdown(endsAtMs: duel.endsAtMs!),
                if (duel.status == DuelStatus.pending && !duel.incoming)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            if (showScore) ...[
              const SizedBox(height: RepRushTokens.spaceSm),
              _ScoreLine(duel: duel),
            ],
            ..._actions(),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions() {
    final Widget? action;
    if (duel.status == DuelStatus.pending && duel.incoming) {
      action = Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: _busy ? null : () => _respond(false),
              child: const Text('Decline'),
            ),
          ),
          const SizedBox(width: RepRushTokens.spaceSm),
          Expanded(
            flex: 2,
            child: BrandButton(
              label: 'Accept',
              icon: Icons.sports_kabaddi,
              loading: _busy,
              onPressed: () => _respond(true),
            ),
          ),
        ],
      );
    } else if (duel.status == DuelStatus.active && duel.myReps == null) {
      action = BrandButton(
        label: 'Do your ${movementPlural(duel.movementId)}',
        icon: Icons.play_arrow,
        onPressed: _train,
      );
    } else if (duel.canClaim) {
      action = BrandButton(
        label: 'Claim +${duel.xpReward} XP',
        icon: Icons.redeem,
        loading: _busy,
        onPressed: _claim,
      );
    } else {
      action = null;
    }
    return action == null
        ? const []
        : [const SizedBox(height: RepRushTokens.spaceSm + 2), action];
  }

  Future<void> _respond(bool accept) async {
    setState(() => _busy = true);
    try {
      await ref.read(duelsProvider.notifier).respond(duel.id, accept: accept);
    } catch (error) {
      _snack(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _claim() async {
    setState(() => _busy = true);
    try {
      final claim = await ref.read(duelsProvider.notifier).claim(duel.id);
      _snack('Duel reward claimed: +${claim.xpAwarded} XP');
    } catch (error) {
      _snack(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Straight into the duel's exercise, in the hex you are standing in.
  Future<void> _train() async {
    ref.read(selectedMovementProvider.notifier).select(duel.movementId);
    await startTraining(context, ref);
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

/// "You 18 — 10 rival_kat", with a dash for a set not yet in.
class _ScoreLine extends StatelessWidget {
  const _ScoreLine({required this.duel});

  final Duel duel;

  @override
  Widget build(BuildContext context) {
    final mine = duel.myReps;
    final theirs = duel.theirReps;
    final leading = (mine ?? -1) > (theirs ?? -1);
    final trailing = (theirs ?? -1) > (mine ?? -1);
    Widget side(String label, int? reps, bool ahead, TextAlign align) =>
        Expanded(
          child: Column(
            crossAxisAlignment: align == TextAlign.start
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.end,
            children: [
              Text(
                reps == null ? '—' : '$reps',
                style: RepRushTokens.statNumber.copyWith(
                  color: ahead ? RepRushTokens.brand : Colors.white,
                ),
              ),
              Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: RepRushTokens.bodyLabel,
              ),
            ],
          ),
        );
    return Row(
      children: [
        side('You', mine, leading, TextAlign.start),
        Text(
          'VS',
          style: RepRushTokens.sectionTitle.copyWith(
            color: playerColor,
            fontSize: 16,
          ),
        ),
        side(duel.opponentHandle, theirs, trailing, TextAlign.end),
      ],
    );
  }
}

/// Minutes and seconds until [endsAtMs], ticking once a second.
class _Countdown extends StatefulWidget {
  const _Countdown({required this.endsAtMs});

  final int endsAtMs;

  @override
  State<_Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<_Countdown> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = Duration(
      milliseconds: (widget.endsAtMs - DateTime.now().millisecondsSinceEpoch)
          .clamp(0, 1 << 31),
    );
    final mm = left.inMinutes.toString();
    final ss = (left.inSeconds % 60).toString().padLeft(2, '0');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.timer_outlined, size: 16, color: playerColor),
        const SizedBox(width: 4),
        Text(
          '$mm:$ss',
          style: const TextStyle(
            fontFamily: RepRushTokens.displayFont,
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: playerColor,
          ),
        ),
      ],
    );
  }
}
