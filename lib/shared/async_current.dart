/// Reading an [AsyncValue] without showing data that no longer applies.
///
/// Riverpod keeps a provider's previous value through a reload and through a
/// failed load. Usually that is a kindness — a poll does not blank the screen
/// — but after switching Live ↔ Demo the previous value is the OTHER mode's
/// data: demo hexes drawn on the live map, demo power on a live capture bar.
/// Every read of mode-specific data picks one of these two instead of
/// `.value`.
///
/// Ownership: C.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

extension CurrentAsync<T> on AsyncValue<T> {
  /// Only data this state loaded itself — nothing carried over while it
  /// reloads or after it fails. For data where a stale value would mislead.
  T? get current => this is AsyncData<T> ? value : null;

  /// The value until a load fails — kept through a quiet poll or refresh,
  /// dropped once the latest load is known to have failed.
  T? get unlessFailed => hasError ? null : value;
}
