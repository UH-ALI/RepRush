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

  static const double cornerCard = 16;
  static const double cornerChip = 8;

  /// The venue-green brand seed.
  static const Color brand = Color(0xFF3DBB6E);
}

/// The three ownership states shown on the map and boards.
enum Ownership {
  yours(color: Color(0xFF3DBB6E), label: 'Yours', icon: Icons.flag),
  rival(color: Color(0xFFEF6C57), label: 'Rival', icon: Icons.shield),
  unclaimed(
    color: Color(0xFF9AA0A6),
    label: 'Unclaimed',
    icon: Icons.radio_button_unchecked,
  );

  const Ownership({
    required this.color,
    required this.label,
    required this.icon,
  });

  final Color color;

  /// N9: the text label is always rendered alongside the colour.
  final String label;

  /// N9: the icon is always rendered alongside the colour.
  final IconData icon;

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
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(RepRushTokens.cornerCard),
      ),
      color: scheme.surfaceContainerHigh,
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
