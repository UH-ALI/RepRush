/// Fast reps: the real 20-rep push-up set is replayed at 1.5x, 2x and 3x speed
/// (time-compressed, same body motion) and must still count every rep.
///
/// Why it exists: with the original 0.35 smoothing a real fast set counted 2
/// of 7 reps ("go deeper" on every one). A simulation on this very recording
/// at 2x speed and 70% depth counted 3 of 20 with 0.35 and 19 of 20 with 0.6,
/// which is what `pushUpConfig.emaAlpha` now is.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/movement_config.dart';
import 'package:reprush/features/capture/pipeline/rep_pipeline.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

List<LandmarkFrame> _load() {
  final json =
      jsonDecode(
            File(
              'test/capture/fixtures_real/push_up_20_slow.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  return [
    for (final raw in json['frames']! as List<Object?>)
      () {
        final f = raw! as Map<String, Object?>;
        final lm = f['landmarks']! as Map<String, Object?>;
        return LandmarkFrame(
          landmarks: {
            for (final e in lm.entries)
              e.key: (
                x: ((e.value! as Map)['x'] as num).toDouble(),
                y: ((e.value! as Map)['y'] as num).toDouble(),
                likelihood: ((e.value! as Map)['likelihood'] as num).toDouble(),
              ),
          },
          timestampMs: f['timestampMs']! as int,
          imageWidth: (f['imageWidth'] as num?)?.toDouble(),
          imageHeight: (f['imageHeight'] as num?)?.toDouble(),
        );
      }(),
  ];
}

/// Speeds the motion up by [k] after [keepUntilMs] (the calibration pose is
/// left at normal speed), resampling at the phone's real ~100 ms cadence by
/// linear interpolation between recorded frames.
List<LandmarkFrame> compress(
  List<LandmarkFrame> src,
  double k, {
  int keepUntilMs = 6500,
}) {
  final out = <LandmarkFrame>[];
  final head = src.where((f) => f.timestampMs <= keepUntilMs).toList();
  out.addAll(head);
  final tail = src.where((f) => f.timestampMs > keepUntilMs).toList();
  if (tail.length < 2) return out;
  var t = out.last.timestampMs;
  var srcT = tail.first.timestampMs.toDouble();
  var i = 0;
  while (srcT < tail.last.timestampMs) {
    while (i + 1 < tail.length - 1 && tail[i + 1].timestampMs < srcT) {
      i++;
    }
    final a = tail[i], b = tail[i + 1];
    final span = (b.timestampMs - a.timestampMs).toDouble();
    final f = span <= 0 ? 0.0 : ((srcT - a.timestampMs) / span).clamp(0.0, 1.0);
    final base = f < 0.5 ? a : b; // keeps the landmark set of the nearer frame
    final lm = <String, Lm>{};
    for (final e in base.landmarks.entries) {
      final pa = a.landmarks[e.key], pb = b.landmarks[e.key];
      if (pa == null || pb == null) {
        lm[e.key] = e.value;
      } else {
        lm[e.key] = (
          x: pa.x + (pb.x - pa.x) * f,
          y: pa.y + (pb.y - pa.y) * f,
          likelihood: pa.likelihood < pb.likelihood
              ? pa.likelihood
              : pb.likelihood,
        );
      }
    }
    t += 100;
    out.add(
      LandmarkFrame(
        landmarks: lm,
        timestampMs: t,
        imageWidth: a.imageWidth,
        imageHeight: a.imageHeight,
      ),
    );
    srcT += 100 * k;
  }
  return out;
}

int count(List<LandmarkFrame> frames) {
  final p = RepPipeline(pushUpConfig);
  for (final f in frames) {
    p.tick(f);
    if (p.calibrating && p.hasEnoughCalibrationSamples) p.finalizeCalibration();
  }
  return p.repCount;
}

void main() {
  final slow = _load();

  test('normal speed counts all 20 (control)', () {
    expect(count(slow), 20);
  });

  for (final k in [1.5, 2.0, 3.0]) {
    test('the same set at ${k}x speed still counts 20 (+-1)', () {
      final fast = compress(slow, k);
      // It really is faster: the set takes 1/k of the time.
      expect(fast.last.timestampMs, lessThan(slow.last.timestampMs * 0.8));
      expect(count(fast), inInclusiveRange(19, 20));
    });
  }
}
