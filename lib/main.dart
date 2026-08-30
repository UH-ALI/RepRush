/// RepRush entry point.
///
/// State management is Riverpod per docs/api-contract.md §state — the whole
/// app lives inside a [ProviderScope]. See `lib/app/app.dart` for the shell
/// and navigation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/app.dart';

void main() {
  runApp(const ProviderScope(child: RepRushApp()));
}
