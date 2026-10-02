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
  ///
  /// [meta] is extra descriptive data (what the app counted, fps, build
  /// mode). Replay loaders ignore unknown keys. Frames also carry the image
  /// size when known, so replays can run the size-dependent checks.
  String exportJson({
    String movement = 'squat',
    int expectedReps = 0,
    Map<String, Object?> meta = const {},
  }) {
    final payload = {
      'movement': movement,
      'expectedReps': expectedReps,
      ...meta,
      'frames': [
        for (final frame in _frames)
          {
            'timestampMs': frame.timestampMs,
            if (frame.imageWidth != null) 'imageWidth': frame.imageWidth,
            if (frame.imageHeight != null) 'imageHeight': frame.imageHeight,
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
