/// Spots feature providers (feature-scoped — §state rule 1).
///
/// Ownership: B (data).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/core/api/stub/stub_repositories.dart' show DemoVenue;
import 'package:reprush/models/models.dart';

/// `GET /spots/nearby?lat=&lng=&radiusM=` — seeded venue spots for Slice 1.
final nearbySpotsProvider = FutureProvider<List<SpotSummary>>((ref) {
  return ref
      .watch(spotsRepositoryProvider)
      .nearby(lat: DemoVenue.lat, lng: DemoVenue.lng);
});

/// `GET /spots/:id/board?tab=` — power / PR count / achievement points (E4).
final spotBoardProvider =
    FutureProvider.family<List<BoardRow>, ({String spotId, BoardTab tab})>((
      ref,
      key,
    ) {
      return ref.watch(spotsRepositoryProvider).board(key.spotId, key.tab);
    });
