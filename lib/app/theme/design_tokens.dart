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

  /// Electric cyan is the primary action colour; violet adds depth without
  /// changing the semantic meaning of ownership or coaching states.
  static const Color brand = Color(0xFF48E5FF);
  static const Color brandDark = Color(0xFF1687D4);
  static const Color electricViolet = Color(0xFF9B6CFF);
  static const Color electricMagenta = Color(0xFFFF4FD8);
  static const Color surfaceDark = Color(0xFF070A16);
  static const Color surfaceMid = Color(0xFF11182B);
  static const Color surfaceRaised = Color(0xFF18233D);
  static const LinearGradient brandGradient = LinearGradient(
    colors: [Color(0xFF159DB8), Color(0xFF5A4BC4)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient surfaceGradient = LinearGradient(
    colors: [Color(0xFF1A2440), Color(0xFF070A16)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const LinearGradient cardGradient = LinearGradient(
    colors: [Color(0x332D78C8), Color(0x121B2D5C)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const List<BoxShadow> brandGlow = [
    BoxShadow(color: Color(0x5548E5FF), blurRadius: 10, spreadRadius: 0),
    BoxShadow(color: Color(0x229B6CFF), blurRadius: 18),
  ];
  static const List<BoxShadow> cardShadow = [
    BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x3348E5FF), blurRadius: 1),
  ];
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 350);
  static const Duration slow = Duration(milliseconds: 700);

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
    color: Color(0xFFD5DCEC),
  );

  /// Coaching amber — "still time to correct" (pipeline DESCENDING cue).
  static const Color feedbackAmber = Color(0xFFFFB84D);

  /// Coaching red — failure states (shallow return, tracking lost).
  static const Color feedbackRed = Color(0xFFFF5577);
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
      bodyLarge: TextStyle(color: Color(0xFFF4F7FF), height: 1.4),
      bodyMedium: TextStyle(color: Color(0xFFE1E6F2), height: 1.4),
      bodySmall: TextStyle(color: Color(0xFFB9C3D8), height: 1.35),
      labelLarge: TextStyle(color: Color(0xFFF4F7FF), fontWeight: FontWeight.w700),
    ),
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      titleTextStyle: RepRushTokens.sectionTitle.copyWith(color: Color(0xFFF4F7FF)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xEE0B1021),
      indicatorColor: RepRushTokens.brand.withValues(alpha: .18),
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w700),
      ),
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
        foregroundColor: RepRushTokens.surfaceDark,
        backgroundColor: RepRushTokens.brand,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
      ),
      side: BorderSide(color: RepRushTokens.brand.withValues(alpha: 0.22)),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
