/// Opt-in recording of capture traces to files on the phone, so real sets can
/// be pulled to a PC and turned into replay fixtures (roles.md A-15).
///
/// Switched on with `--dart-define=REPRUSH_RECORD=true`. Off by default, in
/// every build mode, so normal use never writes anything.
///
/// What is saved is numbers only: per-frame body-point positions and
/// confidences, timestamps, angles. No camera image or video is ever stored
/// or sent. The files stay on the phone until someone copies them off with
/// `adb pull`; they are never uploaded and never part of Evidence.
///
/// Ownership: A. Lives in `data/` (not `pipeline/`) because it touches
/// `dart:io`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

/// True when the app was built with `--dart-define=REPRUSH_RECORD=true`.
const bool kRecordTraces = bool.fromEnvironment('REPRUSH_RECORD');

/// Whether the in-memory recorders run: always in debug (the existing
/// behaviour), and in any build when [kRecordTraces] is set.
bool get recordingEnabled => kDebugMode || kRecordTraces;

/// The app's own external-files folder. Writable without any permission and
/// readable with `adb pull`. Android only; the package id is fixed in
/// `android/app/build.gradle.kts` (`applicationId`).
const String traceDirAndroid =
    '/storage/emulated/0/Android/data/com.example.reprush/files/traces';

/// `yyyyMMdd_HHmmss` — sorts by time and matches the order of your notes.
String traceStamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_'
      '${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

/// Writes [json] to `<traces>/<kind>_<movement>_<stamp>.json` and returns the
/// path, or null when recording is off, the platform is not Android, or the
/// write failed (never throws: a failed save must not disturb a session).
String? writeTraceFile({
  required String kind,
  required String movement,
  required String json,
  DateTime? now,
  String? dirOverride,
}) {
  if (!kRecordTraces && dirOverride == null) return null;
  final dirPath = dirOverride ?? (Platform.isAndroid ? traceDirAndroid : null);
  if (dirPath == null) return null;
  try {
    final dir = Directory(dirPath)..createSync(recursive: true);
    final stamp = traceStamp(now ?? DateTime.now());
    final file = File('${dir.path}/${kind}_${movement}_$stamp.json');
    file.writeAsStringSync(json);
    return file.path;
  } catch (e) {
    debugPrint('RepRush trace: could not save $kind file: $e');
    return null;
  }
}
