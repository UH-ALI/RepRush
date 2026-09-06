/// Evidence builder tests — verifies the pure-Dart EvidenceBuilder produces
/// the exact shape the server parser expects, rejects invalid inputs, and
/// never leaks forbidden fields.
///
/// Reference fixture: `test/server/fixtures/squat_20_clean.json`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/evidence.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';

/// Standard context matching the demo venue.
const _ctx = EvidenceSessionContext(
  sessionId: '00000000-0000-4000-8000-000000000001',
  movementConfigVersion: '2026-08-30.1',
  spotId: null,
  lat: 51.5074,
  lng: -0.1278,
  accuracyM: 12,
);

/// A valid calibration with pixel scale refs.
const _cal = CalibrationResult(
  restSignal: 175,
  startDescent: 163,
  enterPeak: 110,
  enterRest: 150,
  romTarget: 80,
  torsoLengthPx: 420,
  shoulderWidthPx: 260,
);

/// Helper: build N sequential reps with 1-based [index] (the machine's
/// convention) and monotonic timestamps inside [startMs, endMs].
List<RepEvent> _reps(int n, {int startMs = 1000, int endMs = 60000}) {
  final gap = (endMs - startMs) ~/ (n * 2);
  return [
    for (var i = 1; i <= n; i += 1)
      RepEvent(
        index: i,
        tStartMs: startMs + (i - 1) * gap * 2,
        tEndMs: startMs + (i - 1) * gap * 2 + gap,
        restExtreme: 175,
        peakExtreme: 85,
        confMean: 0.9,
        confMin: 0.8,
      ),
  ];
}

void main() {
  group('top-level fields', () {
    test('produces all required top-level keys', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 60000,
        calibration: _cal,
        reps: _reps(3),
        framesTotal: 1000,
        framesDropped: 10,
        fpsMean: 28.5,
      );
      expect(e, isNotNull);
      expect(e!['sessionId'], _ctx.sessionId);
      expect(e['movementConfigVersion'], _ctx.movementConfigVersion);
      expect(e['spotId'], isNull);
      expect(e['location'], isA<Map>());
      expect(e['sets'], isA<List>());
    });

    test('session metadata is echoed verbatim', () {
      const ctx = EvidenceSessionContext(
        sessionId: 'abc-123',
        movementConfigVersion: 'v42',
        spotId: 'spot-7',
        lat: 40.0,
        lng: -74.0,
        accuracyM: 5,
        isMocked: true,
      );
      final e = EvidenceBuilder.build(
        context: ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 2,
        fpsMean: 30.0,
      );
      expect(e!['sessionId'], 'abc-123');
      expect(e['movementConfigVersion'], 'v42');
      expect(e['spotId'], 'spot-7');
    });
  });

  group('location', () {
    test('location block carries all four fields', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      final loc = e!['location'] as Map;
      expect(loc['lat'], 51.5074);
      expect(loc['lng'], -0.1278);
      expect(loc['accuracyM'], 12);
      expect(loc['isMocked'], false);
    });
  });

  group('spotId', () {
    test('null spotId is propagated', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e!['spotId'], isNull);
    });

    test('non-null spotId is propagated', () {
      const ctx = EvidenceSessionContext(
        sessionId: 's1',
        movementConfigVersion: 'v1',
        spotId: 'central-park',
        lat: 40.785,
        lng: -73.968,
        accuracyM: 8,
      );
      final e = EvidenceBuilder.build(
        context: ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e!['spotId'], 'central-park');
    });
  });

  group('set fields', () {
    test('set carries all required keys', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 60000,
        calibration: _cal,
        reps: _reps(2),
        framesTotal: 500,
        framesDropped: 5,
        fpsMean: 29.0,
      );
      final sets = e!['sets'] as List;
      expect(sets, hasLength(1));
      final s = sets.first as Map;
      expect(s['movementId'], 'squat');
      expect(s['measurementType'], 'repBodyweight');
      expect(s['startedAtMs'], 0);
      expect(s['endedAtMs'], 60000);
      expect(s['capture'], isA<Map>());
      expect(s['calibration'], isA<Map>());
      expect(s['reps'], isA<List>());
    });

    test('startedAtMs < 0 is rejected', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: -1,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('endedAtMs <= startedAtMs is rejected', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 5000,
        endedAtMs: 5000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });
  });

  group('capture block', () {
    test('capture carries all four fields', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 300,
        framesDropped: 7,
        fpsMean: 29.4,
      );
      final cap = (e!['sets'] as List).first as Map;
      final c = cap['capture'] as Map;
      expect(c['fpsMean'], 29.4);
      expect(c['framesTotal'], 300);
      expect(c['framesDropped'], 7);
      expect(c['modelVariant'], 'base');
    });
  });

  group('calibration block', () {
    test('calibration carries all three fields', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      final set = (e!['sets'] as List).first as Map;
      final cal = set['calibration'] as Map;
      expect(cal['torsoLengthPx'], 420);
      expect(cal['shoulderWidthPx'], 260);
      expect(cal['restSignal'], 175);
    });

    test('null torsoLengthPx is rejected', () {
      const badCal = CalibrationResult(
        restSignal: 175,
        startDescent: 163,
        enterPeak: 110,
        enterRest: 150,
        romTarget: 80,
        torsoLengthPx: null,
        shoulderWidthPx: 260,
      );
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: badCal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('null shoulderWidthPx is rejected', () {
      const badCal = CalibrationResult(
        restSignal: 175,
        startDescent: 163,
        enterPeak: 110,
        enterRest: 150,
        romTarget: 80,
        torsoLengthPx: 420,
        shoulderWidthPx: null,
      );
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: badCal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('zero pixel value is rejected (< 1)', () {
      const badCal = CalibrationResult(
        restSignal: 175,
        startDescent: 163,
        enterPeak: 110,
        enterRest: 150,
        romTarget: 80,
        torsoLengthPx: 0,
        shoulderWidthPx: 260,
      );
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: badCal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('over-100000 pixel value is rejected', () {
      const badCal = CalibrationResult(
        restSignal: 175,
        startDescent: 163,
        enterPeak: 110,
        enterRest: 150,
        romTarget: 80,
        torsoLengthPx: 420,
        shoulderWidthPx: 100001,
      );
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: badCal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('NaN pixel value is rejected (not finite)', () {
      const badCal = CalibrationResult(
        restSignal: 175,
        startDescent: 163,
        enterPeak: 110,
        enterRest: 150,
        romTarget: 80,
        torsoLengthPx: double.nan,
        shoulderWidthPx: 260,
      );
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: badCal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('Infinity pixel value is rejected (not finite)', () {
      const badCal = CalibrationResult(
        restSignal: 175,
        startDescent: 163,
        enterPeak: 110,
        enterRest: 150,
        romTarget: 80,
        torsoLengthPx: double.infinity,
        shoulderWidthPx: 260,
      );
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: badCal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });
  });

  group('rep fields', () {
    test('rep carries all seven fields with correct names', () {
      final reps = [
        const RepEvent(
          index: 1,
          tStartMs: 1000,
          tEndMs: 3000,
          restExtreme: 175,
          peakExtreme: 82,
          confMean: 0.88,
          confMin: 0.80,
        ),
      ];
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: reps,
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      final r = ((e!['sets'] as List).first as Map)['reps'] as List;
      expect(r, hasLength(1));
      final rep = r.first as Map;
      expect(rep.containsKey('i'), isTrue);
      expect(rep.containsKey('tStartMs'), isTrue);
      expect(rep.containsKey('tEndMs'), isTrue);
      expect(rep.containsKey('restExtreme'), isTrue);
      expect(rep.containsKey('peakExtreme'), isTrue);
      expect(rep.containsKey('confMean'), isTrue);
      expect(rep.containsKey('confMin'), isTrue);
      // No pixel fields in rep
      expect(rep.containsKey('torsoLengthPx'), isFalse);
      expect(rep.containsKey('shoulderWidthPx'), isFalse);
    });

    test('index is converted from 1-based to 0-based', () {
      final reps = _reps(5);
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 60000,
        calibration: _cal,
        reps: reps,
        framesTotal: 500,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      final r = ((e!['sets'] as List).first as Map)['reps'] as List;
      for (var i = 0; i < 5; i += 1) {
        expect((r[i] as Map)['i'], i);
      }
    });

    test('rep outside set window is rejected (before start)', () {
      final reps = [
        const RepEvent(
          index: 1,
          tStartMs: 500, // before startedAtMs = 1000
          tEndMs: 2000,
          restExtreme: 175,
          peakExtreme: 85,
          confMean: 0.9,
          confMin: 0.8,
        ),
      ];
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 1000,
        endedAtMs: 60000,
        calibration: _cal,
        reps: reps,
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('rep outside set window is rejected (after end)', () {
      final reps = [
        const RepEvent(
          index: 1,
          tStartMs: 5000,
          tEndMs: 11000, // after endedAtMs = 10000
          restExtreme: 175,
          peakExtreme: 85,
          confMean: 0.9,
          confMin: 0.8,
        ),
      ];
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: reps,
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('rep with tEndMs <= tStartMs is rejected', () {
      final reps = [
        const RepEvent(
          index: 1,
          tStartMs: 5000,
          tEndMs: 5000, // equal — invalid
          restExtreme: 175,
          peakExtreme: 85,
          confMean: 0.9,
          confMin: 0.8,
        ),
      ];
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 60000,
        calibration: _cal,
        reps: reps,
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('overlapping reps are rejected', () {
      final reps = [
        const RepEvent(
          index: 1,
          tStartMs: 1000,
          tEndMs: 3000,
          restExtreme: 175,
          peakExtreme: 85,
          confMean: 0.9,
          confMin: 0.8,
        ),
        const RepEvent(
          index: 2,
          tStartMs: 2500, // overlaps with rep 1's end at 3000
          tEndMs: 4500,
          restExtreme: 175,
          peakExtreme: 85,
          confMean: 0.9,
          confMin: 0.8,
        ),
      ];
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 60000,
        calibration: _cal,
        reps: reps,
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNull);
    });

    test('ordered non-overlapping reps pass validation', () {
      final reps = [
        const RepEvent(
          index: 1,
          tStartMs: 1000,
          tEndMs: 3000,
          restExtreme: 175,
          peakExtreme: 85,
          confMean: 0.9,
          confMin: 0.8,
        ),
        const RepEvent(
          index: 2,
          tStartMs: 3000, // starts exactly where rep 1 ended
          tEndMs: 5000,
          restExtreme: 175,
          peakExtreme: 85,
          confMean: 0.9,
          confMin: 0.8,
        ),
      ];
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 60000,
        calibration: _cal,
        reps: reps,
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNotNull);
      final r = ((e!['sets'] as List).first as Map)['reps'] as List;
      expect(r, hasLength(2));
    });
  });

  group('forbidden fields', () {
    test('no scoring fields appear in the output', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: _reps(2),
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      final json = e.toString();
      for (final key in [
        'score',
        'repScore',
        'xp',
        'formFactor',
        'romScore',
        'tempoFactor',
        'points',
      ]) {
        expect(json.contains(key), isFalse, reason: 'found forbidden key: $key');
      }
    });

    test('no territory/H3 fields appear in the output', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: _reps(2),
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      final json = e.toString();
      for (final key in [
        'h3',
        'hexH3',
        'startH3',
        'territory',
        'yourPower',
        'winnerPower',
        'flips',
      ]) {
        expect(json.contains(key), isFalse, reason: 'found territory key: $key');
      }
    });

    test('no trace field is included', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      final set = (e!['sets'] as List).first as Map;
      expect(set.containsKey('trace'), isFalse);
    });
  });

  group('edge cases', () {
    test('empty reps list produces a valid set', () {
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: _cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNotNull);
      final r = ((e!['sets'] as List).first as Map)['reps'] as List;
      expect(r, isEmpty);
    });

    test('boundary pixel values (1 and 100000) are accepted', () {
      const cal = CalibrationResult(
        restSignal: 175,
        startDescent: 163,
        enterPeak: 110,
        enterRest: 150,
        romTarget: 80,
        torsoLengthPx: 1,
        shoulderWidthPx: 100000,
      );
      final e = EvidenceBuilder.build(
        context: _ctx,
        movementId: 'squat',
        measurementType: 'repBodyweight',
        startedAtMs: 0,
        endedAtMs: 10000,
        calibration: cal,
        reps: [],
        framesTotal: 100,
        framesDropped: 0,
        fpsMean: 30.0,
      );
      expect(e, isNotNull);
    });
  });
}
