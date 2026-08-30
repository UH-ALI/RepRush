/// Replay test harness (milestone spec §15) — committed fixture traces run
/// through the full pipeline, standing as the regression gate for the
/// counting tunables. Real-phone recordings join these synthetic fixtures
/// in the same directory once recorded via the debug trace recorder.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/squat_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

const _fixturesDir = 'test/capture/fixtures';

class _Fixture {
  _Fixture(this.name, this.movement, this.expectedReps, this.frames);

  final String name;
  final String movement;
  final int expectedReps;
  final List<LandmarkFrame> frames;
}

List<_Fixture> _loadFixtures() {
  final dir = Directory(_fixturesDir);
  final files =
      dir
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files)
      () {
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        final frames = json['frames']! as List<Object?>;
        return _Fixture(
          file.uri.pathSegments.last.replaceAll('.json', ''),
          json['movement']! as String,
          json['expectedReps']! as int,
          [
            for (final raw in frames)
              () {
                final frame = raw! as Map<String, Object?>;
                final landmarks = frame['landmarks']! as Map<String, Object?>;
                return LandmarkFrame(
                  landmarks: {
                    for (final entry in landmarks.entries)
                      entry.key: () {
                        final lm = entry.value! as Map<String, Object?>;
                        return (
                          x: (lm['x']! as num).toDouble(),
                          y: (lm['y']! as num).toDouble(),
                          likelihood: (lm['likelihood']! as num).toDouble(),
                        );
                      }(),
                  },
                  timestampMs: frame['timestampMs']! as int,
                );
              }(),
          ],
        );
      }(),
  ];
}

void main() {
  final fixtures = _loadFixtures();
  if (fixtures.isEmpty) {
    throw StateError('no fixtures found in $_fixturesDir');
  }

  for (final fixture in fixtures) {
    test('${fixture.name}: ${fixture.movement} counts '
        '${fixture.expectedReps} reps', () {
      final pipeline = SquatPipeline(squatConfig);

      // Calibrate on the first 15 standing frames, then count the rest.
      for (final frame in fixture.frames.take(15)) {
        pipeline.tick(frame);
      }
      expect(pipeline.finalizeCalibration(), isTrue);
      for (final frame in fixture.frames.skip(15)) {
        pipeline.tick(frame);
      }

      expect(pipeline.repCount, closeTo(fixture.expectedReps, 1));
      if (fixture.name == 'shallow_squats') {
        // Every shallow movement is flagged locally — never serialized.
        expect(pipeline.shallowAttemptCount, 10);
      } else {
        // Clean and jittery traces must not produce phantom shallows.
        expect(pipeline.shallowAttemptCount, 0);
      }
    });
  }
}
