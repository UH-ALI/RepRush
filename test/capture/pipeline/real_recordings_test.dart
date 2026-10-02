/// Replays REAL phone recordings (numbers only) through the full pipeline
/// the way the capture controller drives it: tick every frame and finalize
/// calibration as soon as enough samples exist.
///
/// Fixtures live in `test/capture/fixtures_real/`, separate from the
/// synthetic squat fixtures that `replay_test.dart` runs.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/rep_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

const _dir = 'test/capture/fixtures_real';

MovementConfig _configFor(String movement) => switch (movement) {
  'squat' => squatConfig,
  'push_up' => pushUpConfig,
  'pull_up' => pullUpConfig,
  _ => throw StateError('unknown movement $movement'),
};

List<LandmarkFrame> _frames(Map<String, Object?> json) => [
  for (final raw in json['frames']! as List<Object?>)
    () {
      final f = raw! as Map<String, Object?>;
      final lm = f['landmarks']! as Map<String, Object?>;
      return LandmarkFrame(
        landmarks: {
          for (final e in lm.entries)
            e.key: () {
              final p = e.value! as Map<String, Object?>;
              return (
                x: (p['x']! as num).toDouble(),
                y: (p['y']! as num).toDouble(),
                likelihood: (p['likelihood']! as num).toDouble(),
              );
            }(),
        },
        timestampMs: f['timestampMs']! as int,
        imageWidth: (f['imageWidth'] as num?)?.toDouble(),
        imageHeight: (f['imageHeight'] as num?)?.toDouble(),
      );
    }(),
];

/// Runs [json] and returns the pipeline after the last frame.
RepPipeline replay(
  Map<String, Object?> json, {
  void Function(LandmarkFrame frame, PipelineFrame result)? onFrame,
}) {
  final pipeline = RepPipeline(_configFor(json['movement']! as String));
  for (final frame in _frames(json)) {
    final result = pipeline.tick(frame);
    onFrame?.call(frame, result);
    if (pipeline.calibrating && pipeline.hasEnoughCalibrationSamples) {
      pipeline.finalizeCalibration();
    }
  }
  return pipeline;
}

void main() {
  final files =
      Directory(_dir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final name = file.uri.pathSegments.last;
    test('$name: ${json['movement']} counts ${json['expectedReps']} reps', () {
      final p = replay(json);
      // ignore: avoid_print
      print('$name -> counted ${p.repCount}, shallow ${p.shallowAttemptCount}');
      expect(p.repCount, json['expectedReps']);
    });
  }
}
