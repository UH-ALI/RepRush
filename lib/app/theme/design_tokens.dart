/// Design tokens and the app theme (roles.md C-2).
///
/// Ownership colours **never carry meaning alone** (requirements.md N9):
/// every ownership state pairs a colour with a text label and an icon.
library;

import 'package:flutter/material.dart';

/// Spacing and corner tokens. C owns; A and B consume (roles.md §5).
abstract final class RepRushTokens {
  static const double spaceXs = 4;
  static const double spaceSm = 8;
  static const double spaceMd = 16;
  static const double spaceLg = 24;
  static const double spaceXl = 32;
  static const double spaceXxl = 48;

  static const double cornerCard = 16;
  static const double cornerChip = 8;

  /// The venue-green brand seed.
  static const Color brand = Color(0xFF3DBB6E);
  static const Color brandDark = Color(0xFF1E8E4E);
  static const Color surfaceDark = Color(0xFF0C1511);
  static const Color surfaceMid = Color(0xFF14231B);
  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF3DBB6E), Color(0xFF1E8E4E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient surfaceGradient = LinearGradient(
    colors: [Color(0xFF17271E), Color(0xFF0C1511)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0x331E8E4E), Color(0x121E8E4E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const List<BoxShadow> brandGlow = [
    BoxShadow(color: Color(0x4D3DBB6E), blurRadius: 18, spreadRadius: 1),
  ];
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x223DBB6E), blurRadius: 1),
  ];
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 350);

  static const TextStyle displayLarge = TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.w800,
    letterSpacing: -1.2,
  );
  static const TextStyle statNumber = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.8,
  );
  static const TextStyle sectionTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
  );
  static const TextStyle bodyLabel = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
    color: Colors.white70,
  );

  /// Coaching amber — "still time to correct" (pipeline DESCENDING cue).
  static const Color feedbackAmber = Color(0xFFFFA726);

  /// Coaching red — failure states (shallow return, tracking lost).
  static const Color feedbackRed = Color(0xFFB3261E);
}

/// The three ownership states shown on the map and boards.
enum Ownership {
  yours(
    color: Color(0xFF3DBB6E),
    label: 'Yours',
    icon: Icons.flag,
    gradient: LinearGradient(colors: [Color(0xFF3DBB6E), Color(0xFF1E8E4E)]),
  ),
  rival(
    color: Color(0xFFEF6C57),
    label: 'Rival',
    icon: Icons.shield,
    gradient: LinearGradient(colors: [Color(0xFFEF6C57), Color(0xFF9E3C40)]),
  ),
  unclaimed(
    color: Color(0xFF9AA0A6),
    label: 'Unclaimed',
    icon: Icons.radio_button_unchecked,
    gradient: LinearGradient(colors: [Color(0xFF9AA0A6), Color(0xFF4E5658)]),
  );

  const Ownership({
    required this.color,
    required this.label,
    required this.icon,
    required this.gradient,
  });

  final Color color;

  /// N9: the text label is always rendered alongside the colour.
  final String label;

  /// N9: the icon is always rendered alongside the colour.
  final IconData icon;
  final LinearGradient gradient;

  /// Maps the wire `ownerColor` / null-owner combos from `HexCell`.
  static Ownership fromWire({String? ownerHandle, required bool yours}) {
    if (yours) return Ownership.yours;
    if (ownerHandle == null) return Ownership.unclaimed;
    return Ownership.rival;
  }
}

/// Live-feedback states for the capture HUD (requirements.md B5/B6) —
/// declared here so tokens exist before Track A lands.
enum LiveFeedbackState {
  green('Tracking — rep counts', Icons.check_circle),
  amber('Fix your form', Icons.warning_amber),
  red('Tracking lost', Icons.error);

  const LiveFeedbackState(this.cue, this.icon);

  final String cue;
  final IconData icon;

  Color get background => switch (this) {
    green => const Color(0xCC123D26),
    amber => const Color(0xCC4A3211),
    red => const Color(0xCC4A1717),
  };

  Color get foreground => switch (this) {
    green => RepRushTokens.brand,
    amber => RepRushTokens.feedbackAmber,
    red => const Color(0xFFFF746A),
  };
}

/// Dark-first Material 3 theme. Ownership is readable on both schemes via
/// label + icon, never colour alone.
ThemeData buildRepRushTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: RepRushTokens.brand,
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: RepRushTokens.surfaceDark,
    textTheme: const TextTheme(
      displayLarge: RepRushTokens.displayLarge,
      headlineMedium: RepRushTokens.sectionTitle,
      titleLarge: RepRushTokens.sectionTitle,
      bodyMedium: TextStyle(height: 1.4),
      labelLarge: TextStyle(fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      titleTextStyle: RepRushTokens.sectionTitle.copyWith(color: Colors.white),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: RepRushTokens.surfaceMid,
      indicatorColor: scheme.primaryContainer,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
      ),
      color: RepRushTokens.surfaceMid,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
      ),
      side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
