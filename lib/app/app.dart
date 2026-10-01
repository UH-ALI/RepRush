/// App shell and navigation (roles.md C-1).
///
/// Four destinations — Map, Train, Compete, Profile. The workout itself is a
/// full-screen route pushed above the shell (Seam 3: A owns the capture view,
/// C owns everything either side of it). The selected tab lives in
/// [shellTabProvider] so screens on pushed routes — the post-set summary — can
/// send the athlete back to the map.
///
/// Ownership: C.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/onboarding.dart';
import 'package:reprush/app/shell_providers.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/challenges/ui/challenges_screen.dart';
import 'package:reprush/features/progression/ui/profile_screen.dart';
import 'package:reprush/features/session/ui/workout_screen.dart';
import 'package:reprush/features/territory/ui/map_screen.dart';

class RepRushApp extends StatelessWidget {
  const RepRushApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RepRush',
      debugShowCheckedModeBanner: false,
      theme: buildRepRushTheme(),
      home: const _FirstRunGate(),
    );
  }
}

/// The intro on first launch, the shell ever after. A failed prefs read
/// falls through to the shell — the intro must never block the game.
class _FirstRunGate extends ConsumerWidget {
  const _FirstRunGate();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(onboardingSeenProvider)) {
      AsyncData(value: false) => const OnboardingScreen(),
      AsyncLoading() => const Scaffold(body: Center(child: HexMark(size: 72))),
      _ => const AppShell(),
    };
  }
}

class AppShell extends ConsumerWidget {
  const AppShell({super.key});

  static const _destinations = {
    ShellTab.map: (Icons.hexagon_outlined, Icons.hexagon, 'Map'),
    ShellTab.train: (Icons.sports_gymnastics, Icons.sports_gymnastics, 'Train'),
    ShellTab.compete: (
      Icons.emoji_events_outlined,
      Icons.emoji_events,
      'Compete',
    ),
    ShellTab.profile: (Icons.person_outline, Icons.person, 'Profile'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(shellTabProvider);
    // IndexedStack keeps each tab's scroll position and provider subscriptions
    // warm, so switching tabs never re-fetches territory or boards.
    return Scaffold(
      body: IndexedStack(
        index: tab.index,
        children: const [
          MapScreen(),
          WorkoutScreen(),
          ChallengesScreen(),
          ProfileScreen(),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: RepRushTokens.chrome,
          border: Border(
            top: BorderSide(color: RepRushTokens.brand.withValues(alpha: .18)),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 68,
            child: Row(
              children: [
                for (final MapEntry(key: destination, value: spec)
                    in _destinations.entries)
                  _NavItem(
                    icon: spec.$1,
                    selectedIcon: spec.$2,
                    label: spec.$3,
                    selected: destination == tab,
                    onTap: () =>
                        ref.read(shellTabProvider.notifier).go(destination),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: RepRushTokens.fast,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
            decoration: BoxDecoration(
              color: selected
                  ? RepRushTokens.brand.withValues(alpha: .16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(99),
            ),
            child: Icon(
              selected ? selectedIcon : icon,
              color: selected ? RepRushTokens.brand : const Color(0xFFB9C3D8),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: selected ? RepRushTokens.brand : const Color(0xFFB9C3D8),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}
