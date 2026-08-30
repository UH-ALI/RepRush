/// App startup test — the shell renders the four destinations and tab
/// navigation works against the stub repositories.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/app/app.dart';

void main() {
  testWidgets('app boots into the Map tab with all four destinations', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));

    expect(find.text('Territory'), findsOneWidget);
    for (final label in const ['Map', 'Workout', 'Profile', 'Challenges']) {
      expect(find.text(label), findsOneWidget);
    }

    // Stub territory loads: the legend is visible and labelled (N9).
    await tester.pumpAndSettle();
    expect(find.text('Yours'), findsOneWidget);
    expect(find.text('Rival'), findsOneWidget);
    expect(find.text('Unclaimed'), findsOneWidget);
  });

  testWidgets('Workout tab shows the session card and capture placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Workout'));
    await tester.pumpAndSettle();

    expect(find.text('No active session'), findsOneWidget);
    expect(find.text('Start session'), findsOneWidget);
    expect(find.text('Camera counter'), findsOneWidget);
    // The seeded Riverside rig is nearby (stub spots); it sits below the
    // fold, so scroll the screen's ListView into range first.
    await tester.scrollUntilVisible(
      find.text('Riverside Calisthenics Rig'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Riverside Calisthenics Rig'), findsOneWidget);
  });

  testWidgets('Profile tab renders the stub profile through providers', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: RepRushApp()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('demo_athlete'), findsOneWidget);
    expect(find.text('Level 3 · 540 XP'), findsOneWidget);
    // The diary teaser sits below the fold in the ListView.
    await tester.scrollUntilVisible(
      find.text('Diary — coming in v2'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Diary — coming in v2'), findsOneWidget);
  });
}
