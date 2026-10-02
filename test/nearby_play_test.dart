/// Nearby play against the stubs: opt-in presence, the scripted duel from
/// challenge to claim, and the map's "go visible" flow.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/app/app.dart';
import 'package:reprush/app/onboarding.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart';
import 'package:reprush/core/location/geo.dart';
import 'package:reprush/features/challenges/ui/duel_widgets.dart';
import 'package:reprush/features/presence/data/presence_providers.dart';
import 'package:reprush/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _here = SessionLocation(
  lat: DemoVenue.lat,
  lng: DemoVenue.lng,
  accuracyM: 5,
);

Map<String, Object?> _evidence(String movementId, int reps) => {
  'sets': [
    {
      'movementId': movementId,
      'reps': [for (var i = 0; i < reps; i++) <String, Object?>{}],
    },
  ],
};

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(StubLedger.sets.clear);

  group('presence stub', () {
    test('three athletes, each in a hex of their own, none in yours', () async {
      final players = await StubPresenceRepository().heartbeat(_here);

      expect(players, hasLength(3));
      expect(players.map((p) => p.h3).toSet(), hasLength(3));
      final own = await const StubTerritoryRepository().hexes(
        swLat: _here.lat - .02,
        swLng: _here.lng - .02,
        neLat: _here.lat + .02,
        neLng: _here.lng + .02,
      );
      expect(own.map((c) => c.h3), containsAll(players.map((p) => p.h3)));
      final mine = hexContaining(own, _here.lat, _here.lng);
      expect(players.map((p) => p.h3), isNot(contains(mine?.h3)));
    });

    test('nearby player round-trips through JSON', () async {
      final player = (await StubPresenceRepository().heartbeat(_here)).first;
      final again = NearbyPlayer.fromJson(player.toJson());
      expect(again.toJson(), player.toJson());
    });
  });

  group('duel stub', () {
    late int now;
    late StubDuelsRepository duels;
    final opponent = StubPresenceRepository.players.first;

    setUp(() {
      now = 1000000;
      duels = StubDuelsRepository(now: () => now);
    });

    test('challenge → accept → both sets → won → claim once', () async {
      final sent = await duels.challenge(
        opponentId: opponent.userId,
        movementId: 'squat',
      );
      expect(sent.status, DuelStatus.pending);
      expect(sent.incoming, isFalse);

      now += StubDuelsRepository.acceptAfterMs;
      var duel = (await duels.list()).single;
      expect(duel.status, DuelStatus.active);
      expect(duel.myReps, isNull);
      expect(duel.endsAtMs, isNotNull);

      // A set before the window opened would not count; this one does.
      now += 5000;
      StubLedger.recordEvidence(_evidence('squat', 18), atMs: now);
      // So would a second, better set — only the first counts.
      StubLedger.recordEvidence(_evidence('squat', 40), atMs: now + 1);
      duel = (await duels.list()).single;
      expect(duel.status, DuelStatus.active);
      expect(duel.myReps, 18);
      expect(duel.theirReps, isNull);

      now += StubDuelsRepository.theirSetAfterMs;
      duel = (await duels.list()).single;
      expect(duel.status, DuelStatus.finished);
      expect(duel.result, 'won');
      expect(duel.xpReward, StubDuelsRepository.winXp);
      expect(duel.canClaim, isTrue);

      final claim = await duels.claim(duel.id);
      expect(claim.xpAwarded, StubDuelsRepository.winXp);
      expect((await duels.list()).single.claimed, isTrue);
      await expectLater(
        duels.claim(duel.id),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.alreadyClaimed,
          ),
        ),
      );
    });

    test('a set of another exercise does not count', () async {
      await duels.challenge(opponentId: opponent.userId, movementId: 'squat');
      now += StubDuelsRepository.acceptAfterMs + 1;
      StubLedger.recordEvidence(_evidence('push_up', 30), atMs: now);
      expect((await duels.list()).single.myReps, isNull);
    });

    test('no claim before the duel finishes, and none without a set', () async {
      final duel = await duels.challenge(
        opponentId: opponent.userId,
        movementId: 'squat',
      );
      await expectLater(
        duels.claim(duel.id),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.duelClosed,
          ),
        ),
      );

      // Window closes with no set from you: finished, lost, nothing to claim.
      now += StubDuelsRepository.acceptAfterMs + StubDuelsRepository.windowMs;
      final over = (await duels.list()).single;
      expect(over.status, DuelStatus.finished);
      expect(over.result, 'lost');
      expect(over.canClaim, isFalse);
    });

    test('one open duel per opponent', () async {
      await duels.challenge(opponentId: opponent.userId, movementId: 'squat');
      await expectLater(
        duels.challenge(opponentId: opponent.userId, movementId: 'push_up'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.duelAlreadyOpen,
          ),
        ),
      );
    });

    test('duel round-trips through JSON', () async {
      final duel = await duels.challenge(
        opponentId: opponent.userId,
        movementId: 'squat',
      );
      expect(Duel.fromJson(duel.toJson()).toJson(), duel.toJson());
    });

    test('the map headlines a reward to claim over a running duel', () async {
      final a = await duels.challenge(
        opponentId: StubPresenceRepository.players[0].userId,
        movementId: 'squat',
      );
      now += StubDuelsRepository.acceptAfterMs + 1;
      StubLedger.recordEvidence(_evidence('squat', 20), atMs: now);
      now += StubDuelsRepository.theirSetAfterMs;
      await duels.challenge(
        opponentId: StubPresenceRepository.players[1].userId,
        movementId: 'push_up',
      );
      now += StubDuelsRepository.acceptAfterMs;
      expect(headlineDuel(await duels.list())?.id, a.id);
    });
  });

  testWidgets('going visible puts nearby athletes on the map', (tester) async {
    SharedPreferences.setMockInitialValues({
      OnboardingController.prefsKey: true,
    });
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await settle(tester);

    // Hidden by default: nobody else on the map.
    expect(find.text('R'), findsNothing);

    await tester.tap(find.byIcon(Icons.visibility_off));
    await settle(tester);
    expect(find.text('Play with people nearby'), findsOneWidget);
    await tester.tap(find.text('Go visible'));
    await settle(tester);

    // The sheet now lists who is around, each with a Duel button.
    expect(find.text("You're visible nearby"), findsOneWidget);
    // On the map pin and in the sheet's list.
    expect(find.text('rival_kat'), findsWidgets);
    expect(find.text('Duel'), findsNWidgets(3));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PresenceVisibilityController.prefsKey), isTrue);

    // Drop the tree, then let the pending poll timers fire into a disposed
    // provider so the loop exits.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(presencePollInterval + const Duration(seconds: 1));
  });
}
