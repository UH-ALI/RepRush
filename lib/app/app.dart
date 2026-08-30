/// App shell and navigation (roles.md C-1).
///
/// Four destinations — Map, Workout, Profile, Challenges. The capture flow
/// embeds inside Workout (Seam 3): A owns the capture screen, C owns
/// everything either side of it.
///
/// Ownership: C.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/challenges/ui/challenges_screen.dart';
import 'package:reprush/features/session/ui/workout_screen.dart';
import 'package:reprush/features/territory/ui/map_screen.dart';
import 'package:reprush/features/progression/ui/profile_screen.dart';

class RepRushApp extends StatelessWidget {
  const RepRushApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RepRush',
      debugShowCheckedModeBanner: false,
      theme: buildRepRushTheme(),
      home: const AppShell(),
    );
  }
}

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const _destinations = [
    NavigationDestination(
      icon: Icon(Icons.hexagon_outlined),
      selectedIcon: Icon(Icons.hexagon),
      label: 'Map',
    ),
    NavigationDestination(
      icon: Icon(Icons.fitness_center_outlined),
      selectedIcon: Icon(Icons.fitness_center),
      label: 'Workout',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: 'Profile',
    ),
    NavigationDestination(
      icon: Icon(Icons.emoji_events_outlined),
      selectedIcon: Icon(Icons.emoji_events),
      label: 'Challenges',
    ),
  ];

  static const _screens = [
    MapScreen(),
    WorkoutScreen(),
    ProfileScreen(),
    ChallengesScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    // IndexedStack keeps each feature's provider subscriptions warm so tab
    // switches never re-fetch territory or boards.
    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: _destinations,
      ),
    );
  }
}
