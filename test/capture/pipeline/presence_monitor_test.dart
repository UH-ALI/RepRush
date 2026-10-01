import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/presence_monitor.dart';

void main() {
  group('PresenceMonitor', () {
    test('a short dropout (flicker) shows nothing', () {
      final m = PresenceMonitor();
      var s = PresenceStatus.present;
      for (var t = 0; t < 500; t += 66) {
        s = m.tick(bodyVisible: false, repCount: 5, timestampMs: t);
      }
      expect(s.stage, PresenceStage.present);
      expect(
        m.tick(bodyVisible: true, repCount: 5, timestampMs: 560).stage,
        PresenceStage.present,
      );
    });

    test('warns after 600 ms and ends the set at 2 s of absence', () {
      final m = PresenceMonitor();
      m.tick(bodyVisible: false, repCount: 5, timestampMs: 1000);
      final warn = m.tick(bodyVisible: false, repCount: 5, timestampMs: 1700);
      expect(warn.isAbsent, isTrue);
      expect(warn.remainingMs, 1300);
      expect(
        m.tick(bodyVisible: false, repCount: 5, timestampMs: 3000).hasLeft,
        isTrue,
      );
    });

    test(
      'returning inside the grace cancels the warning and resets the clock',
      () {
        final m = PresenceMonitor();
        m.tick(bodyVisible: false, repCount: 5, timestampMs: 0);
        expect(
          m.tick(bodyVisible: false, repCount: 5, timestampMs: 1500).isAbsent,
          isTrue,
        );
        expect(
          m.tick(bodyVisible: true, repCount: 5, timestampMs: 1600).stage,
          PresenceStage.present,
        );
        // New absence starts a fresh run, not the old one.
        m.tick(bodyVisible: false, repCount: 5, timestampMs: 1700);
        expect(
          m.tick(bodyVisible: false, repCount: 5, timestampMs: 2200).stage,
          PresenceStage.present,
        );
      },
    );

    test('leaving latches: coming back does not resume the same set', () {
      final m = PresenceMonitor();
      m.tick(bodyVisible: false, repCount: 5, timestampMs: 0);
      m.tick(bodyVisible: false, repCount: 5, timestampMs: 2500);
      expect(
        m.tick(bodyVisible: true, repCount: 5, timestampMs: 3000).hasLeft,
        isTrue,
      );
      m.reset();
      expect(
        m.tick(bodyVisible: true, repCount: 0, timestampMs: 0).stage,
        PresenceStage.present,
      );
    });

    test('nothing to protect before the first rep', () {
      final m = PresenceMonitor();
      for (var t = 0; t < 10000; t += 66) {
        expect(
          m.tick(bodyVisible: false, repCount: 0, timestampMs: t).stage,
          PresenceStage.present,
        );
      }
    });
  });

  group('BodyScaleMonitor', () {
    void feed(BodyScaleMonitor m, double px, int n, {bool atRest = true}) {
      for (var i = 0; i < n; i++) {
        m.tick(torsoPx: px, calibratedTorsoPx: 200, atRest: atRest);
      }
    }

    test('same body (small jitter) is not flagged', () {
      final m = BodyScaleMonitor();
      for (final px in [196, 204, 199, 207, 193, 201, 198, 205, 202, 200]) {
        m.tick(torsoPx: px.toDouble(), calibratedTorsoPx: 200, atRest: true);
      }
      expect(m.medianRatio, closeTo(1.0, 0.03));
      expect(m.mismatch, isFalse);
    });

    test('a clearly different body size is flagged', () {
      final m = BodyScaleMonitor();
      feed(m, 140, 10); // 30% smaller
      expect(m.mismatch, isTrue);
    });

    test('needs a full window before judging', () {
      final m = BodyScaleMonitor();
      feed(m, 140, 9);
      expect(m.mismatch, isFalse);
      expect(m.medianRatio, isNull);
    });

    test('mid-rep frames are ignored (squat lean shortens the torso)', () {
      final m = BodyScaleMonitor();
      feed(m, 130, 50, atRest: false);
      expect(m.mismatch, isFalse);
    });

    test('a few outlier frames do not trigger it (median)', () {
      final m = BodyScaleMonitor();
      feed(m, 200, 7);
      feed(m, 120, 3);
      expect(m.mismatch, isFalse);
    });

    test('missing measurements are skipped and the flag is sticky', () {
      final m = BodyScaleMonitor();
      m.tick(torsoPx: null, calibratedTorsoPx: 200, atRest: true);
      m.tick(torsoPx: 200, calibratedTorsoPx: null, atRest: true);
      expect(m.mismatch, isFalse);
      feed(m, 140, 10);
      expect(m.mismatch, isTrue);
      feed(m, 200, 20);
      expect(m.mismatch, isTrue);
      m.reset();
      expect(m.mismatch, isFalse);
    });
  });
}
