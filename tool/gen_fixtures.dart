// One-off generator for the synthetic replay fixtures (milestone spec §15).
// Regenerate with: dart run tool/gen_fixtures.dart
//
// Geometry matches test/capture/pipeline/squat_pipeline_test.dart: knee at
// the origin, hip at (100, 0), ankle at angle theta so kneeAngle == theta.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const _frameMs = 66; // ~15 fps

Map<String, Object> _landmarks(double angle, double visibility) {
  final rad = angle * math.pi / 180;
  final ankle = {
    'x': 100 * math.cos(rad),
    'y': 100 * math.sin(rad),
    'likelihood': visibility,
  };
  const hip = {'x': 100.0, 'y': 0.0, 'likelihood': 0.9};
  const knee = {'x': 0.0, 'y': 0.0, 'likelihood': 0.9};
  return {
    'leftHip': hip,
    'leftKnee': knee,
    'leftAnkle': ankle,
    'rightHip': hip,
    'rightKnee': knee,
    'rightAnkle': ankle,
  };
}

List<double> _ramp(double from, double to, int steps) => [
  for (var i = 0; i < steps; i += 1) from + (to - from) * i / (steps - 1),
];

/// Builds fixture frames: [calibrationFrames] standing frames at 175°, then
/// [cycles] rest→bottom→rest cycles with [settleFrames] standing frames
/// between them.
List<Map<String, Object>> _frames({
  required int cycles,
  required double bottom,
  required int rampSteps,
  double Function(double angle)? noise,
  int calibrationFrames = 15,
  int settleFrames = 5,
  double visibility = 0.9,
}) {
  final angles = <double>[for (var i = 0; i < calibrationFrames; i += 1) 175];
  for (var rep = 0; rep < cycles; rep += 1) {
    angles
      ..addAll(_ramp(175, bottom, rampSteps))
      ..addAll(_ramp(bottom, 175, rampSteps))
      ..addAll([for (var i = 0; i < settleFrames; i += 1) 175]);
  }
  final rng = math.Random(42);
  return [
    for (var i = 0; i < angles.length; i += 1)
      {
        'timestampMs': i * _frameMs,
        'landmarks': _landmarks(
          noise == null ? angles[i] : angles[i] + noise(rng.nextDouble()),
          visibility,
        ),
      },
  ];
}

void _write(String name, int expectedReps, List<Map<String, Object>> frames) {
  final payload = {
    'movement': 'squat',
    'expectedReps': expectedReps,
    'frames': frames,
  };
  final file = File('test/capture/fixtures/$name.json');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(jsonEncode(payload));
  stdout.writeln('$name: ${frames.length} frames');
}

void main() {
  // 1. Ten smooth full-depth squats — 175° → 80° → 175°.
  _write('clean_10_squats', 10, _frames(cycles: 10, bottom: 80, rampSteps: 15));

  // 2. Ten shallow movements — past startDescent, never past enterPeak.
  _write('shallow_squats', 0, _frames(cycles: 10, bottom: 130, rampSteps: 10));

  // 3. Five squats with ±8° per-frame jitter — real ML Kit noise.
  _write(
    'jittery_5_squats',
    5,
    _frames(
      cycles: 5,
      bottom: 80,
      rampSteps: 15,
      noise: (r) => (r - 0.5) * 16, // ±8° uniform
    ),
  );
}
