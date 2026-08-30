/// Debug-only trace recorder (roles.md A-15 fixture corpus) — captures
/// every [LandmarkFrame] the pipeline processes so real-device sessions
/// become replay-test fixtures.
///
/// Strictly local: traces are never submitted, uploaded, or included in
/// Evidence. Enabled only in debug builds by the controller.
///
/// Ownership: A. Purity rule: plain Dart only (`dart:convert` allowed).
library;

import 'dart:convert';

import 'package:reprush/features/capture/pipeline/types.dart';

class TraceRecorder {
  final List<LandmarkFrame> _frames = [];

  int get frameCount => _frames.length;

  void record(LandmarkFrame frame) => _frames.add(frame);

  /// Serialises to the replay-fixture JSON format (test/capture/fixtures/).
  String exportJson({String movement = 'squat', int expectedReps = 0}) {
    final payload = {
      'movement': movement,
      'expectedReps': expectedReps,
      'frames': [
        for (final frame in _frames)
          {
            'timestampMs': frame.timestampMs,
            'landmarks': {
              for (final entry in frame.landmarks.entries)
                entry.key: {
                  'x': entry.value.x,
                  'y': entry.value.y,
                  'likelihood': entry.value.likelihood,
                },
            },
          },
      ],
    };
    return jsonEncode(payload);
  }

  void clear() => _frames.clear();
}
