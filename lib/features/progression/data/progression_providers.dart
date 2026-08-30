/// Progression feature providers (feature-scoped — §state rule 1).
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/models/models.dart';

/// `GET /me` — handle, level, lifetime RepScore, home spot, unlocked tiers.
final profileProvider = FutureProvider<UserProfile>((ref) {
  return ref.watch(progressionRepositoryProvider).me();
});

/// `GET /movements` — catalogue plus unlocked state and tier progress.
final movementsProvider = FutureProvider<List<Movement>>((ref) {
  return ref.watch(progressionRepositoryProvider).movements();
});
