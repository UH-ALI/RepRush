/// Unit tests for the four-substate rep machine — the most critical
/// component of the counting pipeline.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/calibration.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';

/// Rest 175° with the squat offsets applied.
const _cal = CalibrationResult(
  restSignal: 175,
  startDescent: 163, // 175 - 12
  enterPeak: 110, // 175 - 65
  enterRest: 150, // 175 - 25
  romTarget: 80, // 175 - 95
);

RepMachine machine() => RepMachine(_cal, squatConfig);

/// One full valid squat at the machine level (angles only).
const _validRep = <double>[175.0, 160, 130, 105, 80, 90, 100, 120, 140, 155];

void main() {
  test('a clean rep cycle emits exactly one rep', () {
    final m = machine();
    var t = 0;
    RepMachineResult? last;
    for (final angle in _validRep) {
      last = m.tick(angle, 0.9, t);
      t += 66;
    }
    expect(m.repCount, 1);
    expect(last!.emitted, isNotNull);
    expect(last.emitted!.index, 1);
    expect(last.emitted!.tStartMs, greaterThan(0));
    expect(last.emitted!.tEndMs, t - 66);
    expect(last.phase, RepPhase.rest);
  });

  test('the substates fire in order during a clean rep', () {
    final m = machine();
    expect(m.tick(175, 0.9, 0).phase, RepPhase.rest);
    expect(m.tick(160, 0.9, 66).phase, RepPhase.descending);
    expect(m.tick(105, 0.9, 132).phase, RepPhase.depthReached);
    // One rising frame is not enough (noise guard) — still at depth.
    expect(m.tick(106, 0.9, 198).phase, RepPhase.depthReached);
    // The second consecutive rise confirms ascending.
    expect(m.tick(107, 0.9, 264).phase, RepPhase.ascending);
    expect(m.tick(155, 0.9, 330).phase, RepPhase.rest);
  });

  test('a shallow descent counts nothing and flags the return', () {
    final m = machine();
    m.tick(175, 0.9, 0);
    m.tick(160, 0.9, 66); // descending
    m.tick(140, 0.9, 132); // never crosses enterPeak (110)
    final shallow = m.tick(152, 0.9, 198); // back above enterRest (150)

    expect(m.repCount, 0);
    expect(m.shallowAttemptCount, 1);
    expect(shallow.shallowReturn, isTrue);
    expect(shallow.emitted, isNull);
    expect(shallow.phase, RepPhase.rest);
    // The flag lasts exactly one frame.
    expect(m.tick(175, 0.9, 264).shallowReturn, isFalse);
  });

  test('a 10-rep sequence emits exactly 10 reps', () {
    final m = machine();
    var t = 0;
    var emissions = 0;
    for (var rep = 0; rep < 10; rep += 1) {
      for (final angle in _validRep) {
        final result = m.tick(angle, 0.9, t);
        if (result.emitted != null) emissions += 1;
        t += 66;
      }
    }
    expect(m.repCount, 10);
    expect(emissions, 10);
  });

  test('jitter inside the hysteresis band never counts a rep', () {
    final m = machine();
    m.tick(175, 0.9, 0);
    m.tick(160, 0.9, 66); // descending
    // Bounce between enterPeak (110) and enterRest (150) — neither gate.
    var t = 132;
    for (var i = 0; i < 10; i += 1) {
      m.tick(i.isEven ? 120 : 145, 0.9, t);
      t += 66;
    }
    expect(m.repCount, 0);
    // Returning to standing is a shallow attempt, still not a rep.
    final back = m.tick(155, 0.9, t);
    expect(m.repCount, 0);
    expect(m.shallowAttemptCount, 1);
    expect(back.shallowReturn, isTrue);
  });

  test('tracking loss mid-rep discards the rep without a shallow count', () {
    final m = machine();
    m.tick(175, 0.9, 0);
    m.tick(160, 0.9, 66); // descending
    m.tick(105, 0.9, 132); // depth reached

    // 14 lost frames keep the phase; the 15th resets to rest.
    for (var i = 0; i < 14; i += 1) {
      expect(m.tickLost().phase, RepPhase.depthReached);
    }
    final afterLoss = m.tickLost();
    expect(afterLoss.phase, RepPhase.rest);
    expect(m.repCount, 0);
    expect(m.shallowAttemptCount, 0);
    expect(afterLoss.emitted, isNull);
  });

  test('peakExtreme records the deepest angle of the rep', () {
    final m = machine();
    var t = 0;
    RepEvent? event;
    for (final angle in <double>[175.0, 160, 120, 75, 90, 120, 155]) {
      final result = m.tick(angle, 0.9, t);
      if (result.emitted != null) event = result.emitted;
      t += 66;
    }
    expect(event, isNotNull);
    expect(event!.peakExtreme, closeTo(75, 1e-9));
    expect(event.confMin, closeTo(0.9, 1e-9));
  });

  test('a single rising frame at the bottom does not flip to ascending', () {
    final m = machine();
    m.tick(175, 0.9, 0);
    m.tick(160, 0.9, 66);
    m.tick(105, 0.9, 132); // depth reached
    // +1° blip, inside the 3° margin and only one rising frame.
    expect(m.tick(106, 0.9, 198).phase, RepPhase.depthReached);
    // Dropping again resets the rising streak.
    expect(m.tick(100, 0.9, 264).phase, RepPhase.depthReached);
    expect(m.tick(101, 0.9, 330).phase, RepPhase.depthReached);
  });
}
