import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/data/trace_files.dart';
import 'package:reprush/features/capture/pipeline/trace_recorder.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

void main() {
  group('TraceRecorder.exportJson', () {
    LandmarkFrame frame(int t, {double? w, double? h}) => LandmarkFrame(
      landmarks: {'leftElbow': (x: 1.5, y: 2.5, likelihood: 0.8)},
      timestampMs: t,
      imageWidth: w,
      imageHeight: h,
    );

    test('keeps the replay-fixture shape and adds meta + image size', () {
      final r = TraceRecorder()
        ..record(frame(0, w: 720, h: 1280))
        ..record(frame(66));
      final json =
          jsonDecode(
                r.exportJson(
                  movement: 'push_up',
                  meta: {'appCountedReps': 7, 'fpsMean': 14.2},
                ),
              )
              as Map<String, Object?>;
      expect(json['movement'], 'push_up');
      expect(json['expectedReps'], 0);
      expect(json['appCountedReps'], 7);
      expect(json['fpsMean'], 14.2);
      final frames = json['frames']! as List<Object?>;
      final first = frames[0]! as Map<String, Object?>;
      expect(first['imageWidth'], 720);
      expect(first['imageHeight'], 1280);
      expect(first['landmarks'], {
        'leftElbow': {'x': 1.5, 'y': 2.5, 'likelihood': 0.8},
      });
      // A frame without a known size simply omits the keys.
      final second = frames[1]! as Map<String, Object?>;
      expect(second.containsKey('imageWidth'), isFalse);
    });

    test('contains numbers only: no image or video data', () {
      final r = TraceRecorder()..record(frame(0, w: 720, h: 1280));
      final text = r.exportJson();
      for (final forbidden in ['image"', 'bytes', 'video', 'jpeg', 'base64']) {
        expect(text.contains(forbidden), isFalse, reason: forbidden);
      }
    });
  });

  group('writeTraceFile', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('reprush_trace_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('writes <kind>_<movement>_<stamp>.json with the exact content', () {
      final path = writeTraceFile(
        kind: 'trace',
        movement: 'push_up',
        json: '{"a":1}',
        now: DateTime(2026, 10, 2, 9, 5, 7),
        dirOverride: '${tmp.path}/traces',
      );
      expect(path, isNotNull);
      expect(path!.endsWith('trace_push_up_20261002_090507.json'), isTrue);
      expect(File(path).readAsStringSync(), '{"a":1}');
    });

    test('is off by default: no dir override and no REPRUSH_RECORD', () {
      // `flutter test` runs without --dart-define=REPRUSH_RECORD=true.
      expect(kRecordTraces, isFalse);
      expect(
        writeTraceFile(kind: 'trace', movement: 'squat', json: '{}'),
        isNull,
      );
    });

    test('a failed write returns null instead of throwing', () {
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('x');
      final path = writeTraceFile(
        kind: 'trace',
        movement: 'squat',
        json: '{}',
        dirOverride: '${blocker.path}/sub',
      );
      expect(path, isNull);
    });

    test('stamp is zero-padded and sortable', () {
      expect(traceStamp(DateTime(2026, 1, 2, 3, 4, 5)), '20260102_030405');
    });
  });
}
