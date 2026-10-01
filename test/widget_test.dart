/// App startup test — the shell renders the four destinations and tab
/// navigation works against the stub repositories.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/app/app.dart';
import 'package:reprush/app/onboarding.dart';
import 'package:reprush/features/session/ui/session_summary_screen.dart';
import 'package:reprush/models/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The map's "you are here" pulse loops forever by design, so `pumpAndSettle`
/// would never return. Pump long enough for the stubs to resolve instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  // Every test but the intro's own starts as a returning athlete.
  setUp(() {
    SharedPreferences.setMockInitialValues({
      OnboardingController.prefsKey: true,
    });
  });

  testWidgets('first launch shows the intro, then the map', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await settle(tester);

    expect(find.text('Train anywhere. Claim your ground.'), findsOneWidget);
    expect(find.text('Territory'), findsNothing);

    await tester.tap(find.text("Let's go"));
    await settle(tester);
    expect(find.text('Territory'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(OnboardingController.prefsKey), isTrue);
  });

  testWidgets('app boots into the Map tab with all four destinations', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await settle(tester);

    expect(find.text('Territory'), findsOneWidget);
    for (final label in const ['Map', 'Train', 'Compete', 'Profile']) {
      expect(find.text(label), findsOneWidget);
    }

    // Stub territory loads: the legend is labelled (N9) and the bottom card
    // offers to train for the hex the athlete is standing in.
    await settle(tester);
    expect(find.textContaining('Yours'), findsOneWidget);
    expect(find.textContaining('Rival'), findsOneWidget);
    expect(find.textContaining('Unclaimed'), findsOneWidget);
    expect(
      find.textContaining(
        RegExp('Defend this hex|Take this hex|Claim this hex'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Train tab offers only countable exercises and a start button', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await settle(tester);

    await tester.tap(find.text('Train'));
    await settle(tester);

    expect(find.text('Pick your exercise'), findsOneWidget);
    expect(find.text('Squat'), findsOneWidget);
    expect(find.text('Push-up'), findsOneWidget);
    expect(find.text('Pull-up'), findsOneWidget);
    expect(find.text('Plank'), findsNothing);
    expect(find.text('Start squats'), findsOneWidget);

    // Picking another exercise relabels the start button.
    await tester.tap(find.text('Push-up'));
    await settle(tester);
    expect(find.text('Start push-ups'), findsOneWidget);

    // The seeded Riverside rig is nearby (stub spots), below the fold.
    await tester.scrollUntilVisible(
      find.text('Riverside Calisthenics Rig'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Riverside Calisthenics Rig'), findsOneWidget);
  });

  testWidgets('Compete tab shows the daily challenge and the leaderboard', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await settle(tester);

    await tester.tap(find.text('Compete'));
    await settle(tester);

    expect(find.text('Daily challenge'), findsOneWidget);
    // 20/50 in the stub: not claimable yet.
    expect(find.text('Keep training'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('demo_athlete (you)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('demo_athlete (you)'), findsOneWidget);
  });

  testWidgets('Profile tab renders the stub profile through providers', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await settle(tester);

    await tester.tap(find.text('Profile'));
    await settle(tester);

    expect(find.text('demo_athlete'), findsOneWidget);
    expect(find.text('Level 3 · 540 XP'), findsOneWidget);
    // Rank comes from the territory board (stub: 4th).
    expect(find.text('#4'), findsOneWidget);
  });

  group('small phone (360×740)', () {
    void usePhone(WidgetTester tester) {
      tester.view.physicalSize = const Size(1080, 2220);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
    }

    for (final tab in const ['Map', 'Train', 'Compete', 'Profile']) {
      testWidgets('$tab renders without overflow', (tester) async {
        usePhone(tester);
        await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
        await settle(tester);
        await tester.tap(find.text(tab));
        await settle(tester);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('map pills: owned count in full, hex status flush right', (
      tester,
    ) async {
      usePhone(tester);
      await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
      await settle(tester);

      final owned = tester.renderObject<RenderParagraph>(
        find.text('1 OWNED'),
      );
      expect(owned.didExceedMaxLines, isFalse, reason: 'shown as "1 OW…"');

      // The status pill's right edge lines up with the zoom controls below
      // it (both inset spaceMd = 16 from the 360-wide screen's right edge).
      final status = find.ancestor(
        of: find.textContaining(' HEX'),
        matching: find.byType(DecoratedBox),
      );
      expect(tester.getTopRight(status.first).dx, closeTo(360 - 16, 0.5));
    });

    testWidgets('intro renders without overflow', (tester) async {
      usePhone(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
      await settle(tester);
      expect(find.text("Let's go"), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('summary renders a contested result without overflow', (
      tester,
    ) async {
      usePhone(tester);
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: SessionSummaryScreen(
              repCount: 20,
              movementId: 'push_up',
              result: SubmitResult(
                xp: 240,
                level: 4,
                levelUps: [4],
                hexResult: HexResult(
                  h3: '88195da49bfffff',
                  captured: false,
                  power: 1240,
                  yourPower: 620,
                ),
                spotResult: null,
                rankChange: null,
                unlocks: [],
                prs: [],
                achievements: [],
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Power added'), findsOneWidget);
      expect(find.text('Level up!'), findsOneWidget);
      expect(find.text('See it on the map'), findsOneWidget);
    });
  });
}
