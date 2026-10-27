/// The counting rules added after the first real push-up / pull-up recordings:
/// posture rule (hands off the bar), count-at-peak with a confirm window,
/// rep duration limits, silent wobble, time-based tracking loss.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/rep_context.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

// Pull-up style numbers: dead hang 170, peak 100 (rest - 70), return 150.
const _cal = CalibrationResult(
  restSignal: 170,
  startDescent: 162,
  enterPeak: 100,
  enterRest: 150,
  romTarget: 80,
);

RepMachine pullUp() => RepMachine(_cal, pullUpConfig);
RepMachine squat() => RepMachine(_cal, squatConfig);

/// Feeds [angles] 100 ms apart starting at [t0]; returns the next timestamp.
/// [okAt] decides the posture flag per index (default: always fine).
int feed(
  RepMachine m,
  List<double> angles, {
  int t0 = 0,
  bool Function(int i)? okAt,
  void Function(RepMachineResult r, int i)? each,
}) {
  var t = t0;
  for (var i = 0; i < angles.length; i++) {
    final r = m.tick(angles[i], 0.9, t, contextOk: okAt?.call(i) ?? true);
    each?.call(r, i);
    t += 100;
  }
  return t;
}

// hang, start, down to the top (peak at index 5), then lower back to hang.
// dart format off
// Hang, pull to the top (peak 60 at index 6), then a realistic ~1 s lowering
// back to the hang (indices 7-15).
const _pullUpCycle = <double>[
  170, 170, 150, 120, 95, 70, 60, 65, 70, 80, 95, 110, 130, 150, 165, 170,
];

// A very fast rep: straight back down in three frames.
const _fastCycle = <double>[
  170, 170, 150, 120, 95, 70, 60, 70, 95, 125, 150, 165, 170,
];
// dart format on

void main() {
  group('count at the peak (pull-up)', () {
    test('counts at the top, confirmed shortly after, and only once', () {
      final m = pullUp();
      final countedAt = <int>[];
      feed(
        m,
        _pullUpCycle,
        each: (r, i) {
          if (r.emitted != null) countedAt.add(i);
        },
      );
      expect(m.repCount, 1);
      expect(countedAt, hasLength(1));
      // Peak is index 6 (60 deg); the rep must count while still lowering,
      // well before the return to the hang at index 13-15.
      expect(countedAt.single, lessThan(13));
      expect(countedAt.single, greaterThan(6));
    });

    test('a hand-drop right after the top is vetoed (not counted)', () {
      final m = pullUp();
      var shallow = false;
      feed(
        m,
        _pullUpCycle,
        okAt: (i) => i <= 6, // wrists fall below the shoulders after the peak
        each: (r, i) => shallow = shallow || r.shallowReturn,
      );
      expect(m.repCount, 0);
      expect(m.rejectedCount, 1);
      expect(shallow, isFalse, reason: 'not a "go deeper" situation');
    });

    test('a hand-drop before the peak is vetoed too', () {
      final m = pullUp();
      feed(m, _pullUpCycle, okAt: (i) => i != 3);
      expect(m.repCount, 0);
    });

    test('the same cycle with correct posture still counts (control)', () {
      final m = pullUp();
      feed(m, _pullUpCycle);
      expect(m.repCount, 1);
    });

    test('a very fast clean rep counts when it returns to the hang', () {
      final m = pullUp();
      feed(m, _fastCycle);
      expect(m.repCount, 1);
    });

    test('a very fast rep with the hands dropping is still rejected', () {
      final m = pullUp();
      feed(m, _fastCycle, okAt: (i) => i <= 6);
      expect(m.repCount, 0);
    });

    test('two quick reps back to back both count', () {
      final m = pullUp();
      var t = feed(m, _pullUpCycle);
      feed(m, _pullUpCycle, t0: t);
      expect(m.repCount, 2);
    });
  });

  group('count on return (squat / push-up) honours the posture flag', () {
    // 100 ms steps, ~0.9 s rep.
    const cycle = <double>[170, 160, 130, 95, 80, 100, 130, 155];

    test('counts normally', () {
      final m = squat();
      feed(m, cycle);
      expect(m.repCount, 1);
    });

    test('a broken posture rule voids the rep', () {
      final m = squat();
      feed(m, cycle, okAt: (i) => i != 4);
      expect(m.repCount, 0);
      expect(m.rejectedCount, 1);
    });
  });

  group('rep duration limits', () {
    test('a rep faster than 400 ms is jitter, not a rep', () {
      final m = squat();
      // start at i=1 (t=40), return at i=7 (t=280): 240 ms
      var t = 0;
      for (final a in <double>[170, 160, 130, 95, 80, 100, 130, 155]) {
        m.tick(a, 0.9, t);
        t += 40;
      }
      expect(m.repCount, 0);
    });

    test('a rep stuck for over 10 s is abandoned, not counted', () {
      final m = pullUp();
      final t = feed(m, <double>[170, 150, 120, 95, 70, 60, 70, 80, 90]);
      // Hang at the top for 11 s more (no return to the hang).
      final t2 = feed(m, List.filled(110, 90.0), t0: t);
      // Then lower to the hang.
      feed(m, <double>[120, 160, 170, 170], t0: t2);
      // Counted at the peak (confirmed) before it got stuck: that rep is real.
      expect(m.repCount, 1);
      // The stuck remainder produced nothing more.
      feed(m, <double>[170, 170], t0: t2 + 500);
      expect(m.repCount, 1);
    });

    test('count-on-return reps stuck for over 10 s do not count', () {
      final m = squat();
      final t = feed(m, <double>[170, 150, 120, 95, 80, 95, 110]);
      final t2 = feed(m, List.filled(110, 110.0), t0: t);
      feed(m, <double>[140, 160, 170], t0: t2);
      expect(m.repCount, 0);
      expect(m.rejectedCount, 1);
    });
  });

  group('wobble is silent, real partial reps are flagged', () {
    test('a small bend of the hang (under half way) shows nothing', () {
      final m = pullUp();
      var flagged = false;
      feed(m, <double>[
        170,
        160,
        145,
        140,
        150,
        165,
        170,
      ], each: (r, i) => flagged = flagged || r.shallowReturn);
      expect(flagged, isFalse);
      expect(m.shallowAttemptCount, 0);
      expect(m.repCount, 0);
    });

    test('a genuine partial pull-up is flagged', () {
      final m = pullUp();
      var flagged = false;
      feed(m, <double>[
        170,
        160,
        140,
        120,
        125,
        145,
        155,
        165,
      ], each: (r, i) => flagged = flagged || r.shallowReturn);
      expect(flagged, isTrue);
      expect(m.shallowAttemptCount, 1);
      expect(m.repCount, 0);
    });
  });

  group('tracking loss is measured in time', () {
    RepMachine midRep() {
      final m = pullUp();
      feed(m, <double>[170, 150, 120, 95, 70]);
      return m;
    }

    test('under 3 s of loss keeps the rep alive', () {
      final m = midRep();
      var t = 500;
      RepMachineResult? r;
      while (t <= 500 + 2800) {
        r = m.tickLost(timestampMs: t);
        t += 100;
      }
      expect(r!.phase, isNot(RepPhase.rest));
    });

    test('3 s of loss discards it', () {
      final m = midRep();
      var t = 500;
      RepMachineResult? r;
      while (t <= 500 + 3100) {
        r = m.tickLost(timestampMs: t);
        t += 100;
      }
      expect(r!.phase, RepPhase.rest);
      expect(m.repCount, 0);
    });

    test('a usable frame restarts the loss clock', () {
      final m = midRep();
      for (var t = 500; t < 500 + 2500; t += 100) {
        m.tickLost(timestampMs: t);
      }
      m.tick(70, 0.9, 3100); // back
      var r = m.tickLost(timestampMs: 3200);
      for (var t = 3300; t < 3200 + 2500; t += 100) {
        r = m.tickLost(timestampMs: t);
      }
      expect(r.phase, isNot(RepPhase.rest));
    });
  });

  group('frameContextOk (hands above shoulders)', () {
    Lm p(double x, double y) => (x: x, y: y, likelihood: 0.9);

    // Image y grows downward. Arm length 200 (100 + 100).
    Map<String, Lm> arm({required double wristY, double elbowY = 100}) => {
      'leftShoulder': p(0, 200),
      'leftElbow': p(0, elbowY),
      'leftWrist': p(0, wristY),
    };

    test('dead hang: wrist well above the shoulder -> ok', () {
      // shoulder y=200, elbow y=100, wrist y=0 -> +1.0 / +0.5
      expect(
        frameContextOk(RepContext.handsAboveShoulders, arm(wristY: 0), 'left'),
        isTrue,
      );
    });

    test('top of a pull-up: wrist a little above the shoulder -> ok', () {
      // shoulder 200, elbow 190, wrist 150: above by 0.25 / 0.2
      expect(
        frameContextOk(
          RepContext.handsAboveShoulders,
          arm(wristY: 150, elbowY: 190),
          'left',
        ),
        isTrue,
      );
    });

    test('hands dropped: wrist far below the shoulder -> not ok', () {
      expect(
        frameContextOk(
          RepContext.handsAboveShoulders,
          arm(wristY: 380, elbowY: 290),
          'left',
        ),
        isFalse,
      );
    });

    test('wrist below the elbow (forearm pointing down) -> not ok', () {
      expect(
        frameContextOk(
          RepContext.handsAboveShoulders,
          arm(wristY: 215, elbowY: 190),
          'left',
        ),
        isFalse,
      );
    });

    test('missing joints never veto; no rule always passes', () {
      expect(
        frameContextOk(RepContext.handsAboveShoulders, {}, 'left'),
        isTrue,
      );
      expect(frameContextOk(RepContext.none, arm(wristY: 380), 'left'), isTrue);
    });
  });
}
