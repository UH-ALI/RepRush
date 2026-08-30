/// Unit tests for feedback mapping and debounce timing.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/feedback.dart';
import 'package:reprush/features/capture/pipeline/rep_machine.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

FeedbackSnapshot phase(RepPhase phase) => evaluateFeedback(
  phase: phase,
  trackingLost: false,
  machineResult: const RepMachineResult(
    phase: RepPhase.rest,
    repCount: 0,
    shallowAttemptCount: 0,
  ),
);

void main() {
  group('substate mapping', () {
    test('REST → green Ready', () {
      final f = phase(RepPhase.rest);
      expect(f.level, FeedbackLevel.green);
      expect(f.cue, 'Ready');
    });

    test('DESCENDING → amber Go lower', () {
      final f = phase(RepPhase.descending);
      expect(f.level, FeedbackLevel.amber);
      expect(f.cue, 'Go lower');
    });

    test('DEPTH_REACHED → green Good depth', () {
      final f = phase(RepPhase.depthReached);
      expect(f.level, FeedbackLevel.green);
      expect(f.cue, 'Good depth');
    });

    test('ASCENDING → green Stand tall', () {
      final f = phase(RepPhase.ascending);
      expect(f.level, FeedbackLevel.green);
      expect(f.cue, 'Stand tall');
    });

    test('tracking lost beats every substate', () {
      final f = evaluateFeedback(
        phase: RepPhase.descending,
        trackingLost: true,
        machineResult: null,
      );
      expect(f.level, FeedbackLevel.red);
      expect(f.cue, 'Tracking lost');
    });
  });

  group('event cues', () {
    test('shallow return → red Not counted, immediately', () {
      final f = evaluateFeedback(
        phase: RepPhase.rest,
        trackingLost: false,
        machineResult: const RepMachineResult(
          phase: RepPhase.rest,
          repCount: 0,
          shallowAttemptCount: 1,
          shallowReturn: true,
        ),
      );
      expect(f.level, FeedbackLevel.red);
      expect(f.cue, 'Not counted — go lower next rep');
      expect(f.shallowReturn, isTrue);
    });

    test('valid rep emitted → green Rep counted', () {
      final f = evaluateFeedback(
        phase: RepPhase.rest,
        trackingLost: false,
        machineResult: const RepMachineResult(
          phase: RepPhase.rest,
          repCount: 1,
          shallowAttemptCount: 0,
          emitted: RepEvent(
            index: 1,
            tStartMs: 0,
            tEndMs: 1000,
            restExtreme: 175,
            peakExtreme: 80,
            confMean: 0.9,
            confMin: 0.8,
          ),
        ),
      );
      expect(f.level, FeedbackLevel.green);
      expect(f.cue, 'Rep counted');
      expect(f.repJustCounted, isTrue);
    });
  });

  group('debouncer', () {
    const ready = FeedbackSnapshot(level: FeedbackLevel.green, cue: 'Ready');
    const goLower = FeedbackSnapshot(
      level: FeedbackLevel.amber,
      cue: 'Go lower',
    );

    test('normal transitions hold for three consecutive frames', () {
      final d = FeedbackDebouncer(debounceFrames: 3);
      expect(d.update(ready).cue, 'Ready');
      // Proposed amber must persist for 3 frames before it takes effect.
      expect(d.update(goLower).cue, 'Ready');
      expect(d.update(goLower).cue, 'Ready');
      expect(d.update(goLower).cue, 'Go lower');
    });

    test('an interrupted proposal never takes effect', () {
      final d = FeedbackDebouncer(debounceFrames: 3);
      d.update(ready);
      d.update(goLower);
      d.update(goLower);
      // A different proposal resets the streak.
      expect(d.update(ready).cue, 'Ready');
      expect(d.update(goLower).cue, 'Ready');
    });

    test('shallow-return red fires immediately and holds', () {
      final d = FeedbackDebouncer(debounceFrames: 3, shallowHoldFrames: 2);
      d.update(ready);
      const shallow = FeedbackSnapshot(
        level: FeedbackLevel.red,
        cue: 'Not counted — go lower next rep',
        shallowReturn: true,
      );
      expect(d.update(shallow).shallowReturn, isTrue);
      // Held through the next two frames even though Ready returns.
      expect(d.update(ready).shallowReturn, isTrue);
      expect(d.update(ready).shallowReturn, isTrue);
      expect(d.update(ready).cue, 'Ready');
    });

    test('rep-counted green fires immediately and holds', () {
      final d = FeedbackDebouncer(debounceFrames: 3, repHoldFrames: 1);
      d.update(ready);
      const counted = FeedbackSnapshot(
        level: FeedbackLevel.green,
        cue: 'Rep counted',
        repJustCounted: true,
      );
      expect(d.update(counted).repJustCounted, isTrue);
      expect(d.update(ready).repJustCounted, isTrue);
      expect(d.update(ready).cue, 'Ready');
    });
  });
}
