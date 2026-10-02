/// RepRush entry point.
///
/// State management is Riverpod per docs/api-contract.md §state — the whole
/// app lives inside a [ProviderScope]. See `lib/app/app.dart` for the shell
/// and navigation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/app.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The Live/Demo choice is read before the first frame so the app opens in
  // it, rather than starting in the build default and switching under you.
  ApiMode? savedMode;
  try {
    final prefs = await SharedPreferences.getInstance();
    savedMode = ApiMode.tryParse(prefs.getString(AppModeController.prefsKey));
  } catch (_) {
    // No saved choice: the build default it is.
  }
  runApp(
    ProviderScope(
      overrides: [savedApiModeProvider.overrideWithValue(savedMode)],
      child: const RepRushApp(),
    ),
  );
}
