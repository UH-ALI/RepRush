import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/idle_monitor.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';

/// Drives the monitor at 15 fps from [fromMs] to [toMs] in a constant phase
/// and returns the last status.
IdleStatus _run(
  SetIdleMonitor m, {
  required int fromMs,
  required int toMs,
  RepPhase phase = RepPhase.rest,
  required int reps,
}) {
  var status = IdleStatus.active;
  for (var t = fromMs; t <= toMs; t += 66) {
    status = m.tick(phase: phase, repCount: reps, timestampMs: t);
  }
  return status;
}

/// Feeds [n] completed reps spaced [intervalMs] apart, starting at
/// [startMs]. Returns the timestamp of the last rep.
int _reps(SetIdleMonitor m, int n, int intervalMs, {int startMs = 0}) {
  var t = startMs;
  for (var i = 1; i <= n; i++) {
    t = startMs + i * intervalMs;
    // Mid-rep activity, then the rep completes.
    m.tick(
      phase: RepPhase.descending,
      repCount: i - 1,
      timestampMs: t - intervalMs ~/ 2,
    );
    m.tick(phase: RepPhase.rest, repCount: i, timestampMs: t);
  }
  return t;
}

void main() {
  group('threshold', () {
    test('uses the default until two reps exist', () {
      final m = SetIdleMonitor();
      expect(m.thresholdMs, 8000);
      _reps(m, 1, 2000);
      expect(m.thresholdMs, 8000);
    });

    test('is 3x the median inter-rep interval', () {
      final m = SetIdleMonitor();
      _reps(m, 6, 2500);
      expect(m.thresholdMs, 7500);
    });

    test('is clamped to the floor for very fast reps', () {
      final m = SetIdleMonitor();
      _reps(m, 6, 1000); // 3x = 3000 -> floor 5000
      expect(m.thresholdMs, 5000);
    });

    test('is clamped to the ceiling for very slow reps', () {
      final m = SetIdleMonitor();
      _reps(m, 4, 8000); // 3x = 24000 -> ceiling 15000
      expect(m.thresholdMs, 15000);
    });

    test('one unusually long pause does not distort the tempo (median)', () {
      final m = SetIdleMonitor();
      var t = _reps(m, 4, 2000);
      // one 9 s gap, then two normal reps
      t += 9000;
      m.tick(phase: RepPhase.rest, repCount: 5, timestampMs: t);
      t += 2000;
      m.tick(phase: RepPhase.rest, repCount: 6, timestampMs: t);
      expect(m.thresholdMs, 6000); // median interval 2000
    });
  });

  group('idle flow', () {
    test('never idle before the first rep', () {
      final m = SetIdleMonitor();
      final s = _run(m, fromMs: 0, toMs: 60000, reps: 0);
      expect(s.stage, IdleStage.active);
    });

    test('stays active while reps keep coming', () {
      final m = SetIdleMonitor();
      final last = _reps(m, 10, 2500);
      // 3 s after the last rep: well under the 7.5 s threshold.
      final s = _run(m, fromMs: last, toMs: last + 3000, reps: 10);
      expect(s.stage, IdleStage.active);
    });

    test('warns after the threshold with a 3-2-1 countdown, then expires', () {
      final m = SetIdleMonitor();
      final last = _reps(m, 6, 2500); // threshold 7500
      final seen = <int>[];
      var stage = IdleStage.active;
      for (var t = last; t <= last + 12000; t += 66) {
        final s = m.tick(phase: RepPhase.rest, repCount: 6, timestampMs: t);
        stage = s.stage;
        if (s.isWarning && (seen.isEmpty || seen.last != s.secondsLeft)) {
          seen.add(s.secondsLeft);
        }
      }
      expect(seen, [3, 2, 1]);
      expect(stage, IdleStage.expired);
    });

    test('the warning begins at the threshold, expiry 3 s later', () {
      final m = SetIdleMonitor();
      final last = _reps(m, 6, 2500); // threshold 7500
      expect(
        m
            .tick(phase: RepPhase.rest, repCount: 6, timestampMs: last + 7400)
            .stage,
        IdleStage.active,
      );
      expect(
        m
            .tick(phase: RepPhase.rest, repCount: 6, timestampMs: last + 7600)
            .isWarning,
        isTrue,
      );
      expect(
        m
            .tick(phase: RepPhase.rest, repCount: 6, timestampMs: last + 10500)
            .isExpired,
        isTrue,
      );
    });

    test('movement during the warning cancels it', () {
      final m = SetIdleMonitor();
      final last = _reps(m, 6, 2500);
      final warn = m.tick(
        phase: RepPhase.rest,
        repCount: 6,
        timestampMs: last + 8500,
      );
      expect(warn.isWarning, isTrue);
      // Athlete starts a descent: activity.
      final resumed = m.tick(
        phase: RepPhase.descending,
        repCount: 6,
        timestampMs: last + 9000,
      );
      expect(resumed.stage, IdleStage.active);
      // And the clock restarted from that moment, not from the old rep.
      final later = m.tick(
        phase: RepPhase.rest,
        repCount: 6,
        timestampMs: last + 9000 + 5000,
      );
      expect(later.stage, IdleStage.active);
    });

    test('a rep completing during the warning cancels it', () {
      final m = SetIdleMonitor();
      final last = _reps(m, 6, 2500);
      m.tick(phase: RepPhase.rest, repCount: 6, timestampMs: last + 8000);
      final s = m.tick(
        phase: RepPhase.rest,
        repCount: 7,
        timestampMs: last + 8100,
      );
      expect(s.stage, IdleStage.active);
    });

    test('expiry latches until reset', () {
      final m = SetIdleMonitor();
      final last = _reps(m, 6, 2500);
      expect(
        m
            .tick(phase: RepPhase.rest, repCount: 6, timestampMs: last + 11000)
            .isExpired,
        isTrue,
      );
      // Moving afterwards does not un-expire: the set was already saved.
      expect(
        m
            .tick(
              phase: RepPhase.descending,
              repCount: 6,
              timestampMs: last + 11500,
            )
            .isExpired,
        isTrue,
      );
      m.reset();
      expect(
        m.tick(phase: RepPhase.rest, repCount: 0, timestampMs: 0).stage,
        IdleStage.active,
      );
    });

    test('a slow pull-up rhythm is not mistaken for resting', () {
      final m = SetIdleMonitor();
      // 5 s per rep -> threshold 15 s; 9 s at the bottom is still a set.
      final last = _reps(m, 5, 5000);
      final s = m.tick(
        phase: RepPhase.rest,
        repCount: 5,
        timestampMs: last + 9000,
      );
      expect(s.stage, IdleStage.active);
    });
  });
}
