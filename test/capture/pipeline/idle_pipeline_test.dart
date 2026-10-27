/// Pipeline-level idle behaviour: a pause after a real set raises the
/// 3-2-1 warning and expires; movement during the warning cancels it.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/idle_monitor.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/presence_monitor.dart';
import 'package:reprush/features/capture/pipeline/rep_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

LandmarkFrame _frame(double angle, int t) {
  final rad = angle * math.pi / 180;
  final ankle = (
    x: 100 * math.cos(rad),
    y: 100 * math.sin(rad),
    likelihood: 0.9,
  );
  const hip = (x: 100.0, y: 0.0, likelihood: 0.9);
  const knee = (x: 0.0, y: 0.0, likelihood: 0.9);
  return LandmarkFrame(
    landmarks: {
      'leftHip': hip,
      'leftKnee': knee,
      'leftAnkle': ankle,
      'rightHip': hip,
      'rightKnee': knee,
      'rightAnkle': ankle,
    },
    timestampMs: t,
  );
}

List<double> _ramp(double a, double b, int n) => [
  for (var i = 0; i < n; i++) a + (b - a) * i / (n - 1),
];

/// Calibrated pipeline after [reps] squats of ~2 s each. Returns the
/// pipeline and the running clock.
({RepPipeline p, int t}) _afterSet(int reps) {
  final p = RepPipeline(squatConfig);
  var t = 0;
  for (var i = 0; i < 15; i++) {
    p.tick(_frame(175, t));
    t += 66;
  }
  expect(p.finalizeCalibration(), isTrue);
  for (var r = 0; r < reps; r++) {
    for (final a in [..._ramp(175, 80, 15), ..._ramp(80, 175, 15)]) {
      p.tick(_frame(a, t));
      t += 66;
    }
  }
  return (p: p, t: t);
}

void main() {
  test(
    'standing still after a set warns 3-2-1 then expires; reps are kept',
    () {
      final s = _afterSet(6);
      expect(s.p.repCount, 6);
      var t = s.t;
      final seen = <int>[];
      var stage = IdleStage.active;
      for (var i = 0; i < 300; i++) {
        final f = s.p.tick(_frame(175, t));
        t += 66;
        stage = f.idle.stage;
        if (f.idle.isWarning &&
            (seen.isEmpty || seen.last != f.idle.secondsLeft)) {
          seen.add(f.idle.secondsLeft);
        }
      }
      expect(seen, [3, 2, 1]);
      expect(stage, IdleStage.expired);
      expect(s.p.repCount, 6);
    },
  );

  test('walking out of frame ends the set within ~2 s, not via idle', () {
    final s = _afterSet(6);
    var t = s.t;
    final start = t;
    PipelineFrame? f;
    var sawWarning = false;
    while (t - start < 5000) {
      // No landmarks at all -> tracking-lost path.
      f = s.p.tick(LandmarkFrame(landmarks: const {}, timestampMs: t));
      sawWarning = sawWarning || f.presence.isAbsent;
      if (f.setEndReason != null) break;
      t += 66;
    }
    expect(f!.setEndReason, SetEndReason.leftFrame);
    expect(sawWarning, isTrue);
    expect(t - start, inInclusiveRange(1900, 2100));
    expect(f.idle.isExpired, isFalse, reason: 'ended before the idle timer');
    expect(s.p.repCount, 6, reason: 'reps counted so far are kept');
  });

  test('a dropout shorter than the grace does not end the set', () {
    final s = _afterSet(6);
    var t = s.t;
    for (var i = 0; i < 15; i++) {
      // ~1 s of lost frames.
      final f = s.p.tick(LandmarkFrame(landmarks: const {}, timestampMs: t));
      expect(f.setEndReason, isNull);
      t += 66;
    }
    final back = s.p.tick(_frame(175, t));
    expect(back.presence.stage, PresenceStage.present);
    expect(back.setEndReason, isNull);
  });

  group('body-size consistency (flag only)', () {
    LandmarkFrame withTorso(double torsoPx, int t) {
      // Shift everything into the image: the selector rejects landmarks
      // outside the (1000x1000) bounds, and the base frame sits at the origin.
      const shift = 300.0;
      final base = _frame(175, t);
      final lm = {
        for (final e in base.landmarks.entries)
          e.key: (
            x: e.value.x + shift,
            y: e.value.y + shift,
            likelihood: e.value.likelihood,
          ),
      };
      for (final side in const ['left', 'right']) {
        lm['${side}Shoulder'] = (
          x: 100.0 + shift,
          y: shift - torsoPx,
          likelihood: 0.9,
        );
      }
      return LandmarkFrame(
        landmarks: lm,
        timestampMs: t,
        imageWidth: 1000,
        imageHeight: 1000,
      );
    }

    RepPipeline calibrated(double torsoPx) {
      final p = RepPipeline(squatConfig);
      for (var i = 0; i < 15; i++) {
        p.tick(withTorso(torsoPx, i * 66));
      }
      expect(p.finalizeCalibration(), isTrue);
      expect(p.calibration!.torsoLengthPx, closeTo(torsoPx, 0.5));
      return p;
    }

    test('same torso size is not flagged', () {
      final p = calibrated(200);
      PipelineFrame? f;
      for (var i = 0; i < 20; i++) {
        f = p.tick(withTorso(204, 2000 + i * 66));
      }
      expect(f!.bodyMismatch, isFalse);
      expect(f.torsoRatio, closeTo(1.02, 0.01));
    });

    test('a visibly smaller body at rest is flagged but the set continues', () {
      final p = calibrated(200);
      PipelineFrame? f;
      for (var i = 0; i < 20; i++) {
        f = p.tick(withTorso(140, 2000 + i * 66));
      }
      expect(f!.bodyMismatch, isTrue);
      expect(f.setEndReason, isNull, reason: 'flag only, never ends the set');
    });
  });

  test('resuming during the warning cancels it and counting continues', () {
    final s = _afterSet(6);
    var t = s.t;
    // Rest until the warning appears.
    var warned = false;
    while (!warned) {
      warned = s.p.tick(_frame(175, t)).idle.isWarning;
      t += 66;
    }
    // Do another full rep.
    IdleStage last = IdleStage.expired;
    for (final a in [..._ramp(175, 80, 15), ..._ramp(80, 175, 15)]) {
      last = s.p.tick(_frame(a, t)).idle.stage;
      t += 66;
    }
    for (var i = 0; i < 5; i++) {
      last = s.p.tick(_frame(175, t)).idle.stage;
      t += 66;
    }
    expect(last, IdleStage.active);
    expect(s.p.repCount, 7);
  });

  test('no idle during calibration or before the first rep', () {
    final p = RepPipeline(squatConfig);
    var t = 0;
    for (var i = 0; i < 15; i++) {
      expect(p.tick(_frame(175, t)).idle.stage, IdleStage.active);
      t += 66;
    }
    expect(p.finalizeCalibration(), isTrue);
    for (var i = 0; i < 600; i++) {
      expect(p.tick(_frame(175, t)).idle.stage, IdleStage.active);
      t += 66;
    }
  });
}
