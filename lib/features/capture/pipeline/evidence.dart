/// Evidence assembler (roles.md A-14) — pure Dart, no Flutter, no plugins,
/// no `dart:ui`, no `lib/models/` (that file imports `flutter/foundation.dart`).
///
/// The capture controller passes session context in as parameters — this
/// file never reaches for a provider. The output is a plain
/// `Map<String, Object?>` that `ActiveSessionController.submit()` already
/// accepts, so no typed Evidence class is needed on the client.
///
/// Field names match `supabase/functions/_shared/evidence/schema.ts` and
/// the golden fixture `test/server/fixtures/squat_20_clean.json` verbatim.
///
/// Ownership: A. Purity rule: plain Dart only.
library;

import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';

/// The session-layer values Evidence needs — passed from the UI, sourced
/// from [ActiveSessionController]. Plain Dart, no provider reach.
class EvidenceSessionContext {
  const EvidenceSessionContext({
    required this.sessionId,
    required this.movementConfigVersion,
    required this.spotId,
    required this.lat,
    required this.lng,
    required this.accuracyM,
    this.isMocked = false,
  });

  final String sessionId;

  /// Echoed from `SessionStart.movementConfigVersion` — a mismatch is a
  /// 409 CONFIG_VERSION_MISMATCH.
  final String movementConfigVersion;

  /// Echoed from `SessionStart.spotId` — must match the value `start()`
  /// was called with, null for null.
  final String? spotId;

  /// The exact location used in `POST /session/start` — the server
  /// recorded this and compares Evidence against it within
  /// CONTEXT_MATCH_RADIUS_M (100 m).
  final double lat;
  final double lng;
  final double accuracyM;
  final bool isMocked;
}

/// Builds the Evidence map from collected capture data.
///
/// Returns null when required fields are missing or invalid — never
/// throws. The caller decides what to show the user.
abstract final class EvidenceBuilder {
  /// The seven field names the server recursively forbids at any depth.
  static const Set<String> _forbiddenScoreFields = {
    'score',
    'repScore',
    'xp',
    'formFactor',
    'romScore',
    'tempoFactor',
    'points',
  };

  /// Assembles one set of squat evidence.
  ///
  /// [startedAtMs] and [endedAtMs] are offsets from session start on the
  /// controller's monotonic Stopwatch — never epoch timestamps.
  /// [startedAtMs] must be >= 0; [endedAtMs] must be > [startedAtMs].
  ///
  /// Rep `index` is 1-based on [RepEvent] (the machine counts 1, 2, 3…)
  /// but the server expects 0-based `i` (the fixture runs 0..19). The
  /// conversion happens here — `rep.index - 1` — so the machine's
  /// semantics stay untouched.
  static Map<String, Object?>? build({
    required EvidenceSessionContext context,
    required String movementId,
    required String measurementType,
    required int startedAtMs,
    required int endedAtMs,
    required CalibrationResult calibration,
    required List<RepEvent> reps,
    required int framesTotal,
    required int framesDropped,
    required double fpsMean,
  }) {
    // --- Set window ---
    if (startedAtMs < 0) return null;
    if (endedAtMs <= startedAtMs) return null;

    // --- Calibration (required, finite, [1, 100000]) ---
    final torsoPx = calibration.torsoLengthPx;
    final shoulderPx = calibration.shoulderWidthPx;
    if (torsoPx == null || !_validPx(torsoPx)) return null;
    if (shoulderPx == null || !_validPx(shoulderPx)) return null;

    // --- Reps (ordered, non-overlapping, inside the set window) ---
    final builtReps = <Map<String, Object?>>[];
    int? lastEnd;
    for (final rep in reps) {
      if (rep.tStartMs < startedAtMs) return null;
      if (rep.tEndMs > endedAtMs) return null;
      if (rep.tEndMs <= rep.tStartMs) return null;
      if (lastEnd != null && rep.tStartMs < lastEnd) return null;
      builtReps.add({
        'i': rep.index - 1, // 1-based machine → 0-based Evidence
        'tStartMs': rep.tStartMs,
        'tEndMs': rep.tEndMs,
        'restExtreme': rep.restExtreme,
        'peakExtreme': rep.peakExtreme,
        'confMean': rep.confMean,
        'confMin': rep.confMin,
      });
      lastEnd = rep.tEndMs;
    }

    // --- Capture block ---
    final capture = <String, Object?>{
      'fpsMean': fpsMean,
      'framesTotal': framesTotal,
      'framesDropped': framesDropped,
      'modelVariant': 'base',
    };

    // --- Calibration block ---
    final calibrationBlock = <String, Object?>{
      'torsoLengthPx': torsoPx,
      'shoulderWidthPx': shoulderPx,
      'restSignal': calibration.restSignal,
    };

    // --- Set ---
    final set = <String, Object?>{
      'movementId': movementId,
      'measurementType': measurementType,
      'startedAtMs': startedAtMs,
      'endedAtMs': endedAtMs,
      'capture': capture,
      'calibration': calibrationBlock,
      'reps': builtReps,
    };

    // --- Top level ---
    final evidence = <String, Object?>{
      'sessionId': context.sessionId,
      'movementConfigVersion': context.movementConfigVersion,
      'location': {
        'lat': context.lat,
        'lng': context.lng,
        'accuracyM': context.accuracyM,
        'isMocked': context.isMocked,
      },
      'spotId': context.spotId,
      'sets': [set],
    };

    // Defence in depth: if the map somehow contains a forbidden score
    // key, refuse rather than ship a 422 to the server.
    if (_containsForbidden(evidence)) return null;

    return evidence;
  }

  /// Pixel-distance guard: finite and in [1, 100000].
  static bool _validPx(double v) => v.isFinite && v >= 1 && v <= 100000;

  /// Recursive scan for any key in [_forbiddenScoreFields] at any depth —
  /// mirrors the server's `assertNoScoreFields`.
  static bool _containsForbidden(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is String &&
            _forbiddenScoreFields.contains(entry.key as String)) {
          return true;
        }
        if (_containsForbidden(entry.value)) return true;
      }
    } else if (value is List) {
      for (final item in value) {
        if (_containsForbidden(item)) return true;
      }
    }
    return false;
  }
}
