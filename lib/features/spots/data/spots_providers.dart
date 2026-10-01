/// Spots feature providers (feature-scoped — §state rule 1).
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/models/models.dart';

/// `GET /spots/nearby` around the athlete — the ONE nearby-spots provider; the
/// map and the workout screen both read it.
///
/// Live: spots have no table or route yet (B-12), so this is empty rather than
/// fabricated venue spots drawn next to real territory. Stub: the seeded venue
/// spots around the demo location.
final nearbySpotsProvider = FutureProvider<List<SpotSummary>>((ref) async {
  if (ref.watch(backendConfigProvider).isLive) return const <SpotSummary>[];
  final location = await ref.watch(territoryLocationProvider.future);
  return ref
      .watch(spotsRepositoryProvider)
      .nearby(lat: location.lat, lng: location.lng);
});

/// `GET /spots/:id/board?tab=` — power / PR count / achievement points (E4).
final spotBoardProvider =
    FutureProvider.family<List<BoardRow>, ({String spotId, BoardTab tab})>((
      ref,
      key,
    ) {
      return ref.watch(spotsRepositoryProvider).board(key.spotId, key.tab);
    });
