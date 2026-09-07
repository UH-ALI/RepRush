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
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          height: 72,
          decoration: const BoxDecoration(
            color: Color(0xEE0C1511),
            border: Border(top: BorderSide(color: Color(0x333DBB6E))),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < _destinations.length; i++)
                _NavItem(
                  destination: _destinations[i],
                  selected: i == _index,
                  onTap: () => setState(() => _index = i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.destination, required this.selected, required this.onTap});
  final NavigationDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: RepRushTokens.fast,
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? RepRushTokens.brand.withValues(alpha: .16) : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AnimatedSwitcher(
            duration: RepRushTokens.fast,
            child: selected ? destination.selectedIcon : destination.icon,
          ),
          const SizedBox(height: 3),
          Text(destination.label, style: TextStyle(fontSize: 11, color: selected ? RepRushTokens.brand : Colors.white60, fontWeight: FontWeight.w700)),
        ]),
      ),
    ),
  );
}
