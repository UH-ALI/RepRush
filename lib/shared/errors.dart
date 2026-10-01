/// Athlete-facing copy for every failure the app can surface.
///
/// The server's `message` strings are written for developers — they cite
/// requirement ids ("(J7)", "D4") and name internals — so they are never shown
/// as-is. Each contract code maps to a sentence that says what happened and what
/// to do next. The raw code and message still reach the debug console.
///
/// Ownership: C.
library;

import 'package:flutter/foundation.dart';
import 'package:reprush/core/location/location.dart';
import 'package:reprush/models/models.dart';

/// One line of copy for [error], suitable for a snackbar or an error view.
String describeError(Object error) {
  if (kDebugMode) debugPrint('[RepRush] $error');
  return switch (error) {
    ApiException e => _describeApi(e),
    LocationException e => e.message,
    FormatException() || TypeError() || StateError() =>
      'Something went wrong on our side. Please try again.',
    // Exceptions the app throws on purpose (e.g. TrainingBlocked) carry their
    // own athlete-facing copy in toString().
    _ => error.toString(),
  };
}

String _describeApi(ApiException e) => switch (e.code) {
  ApiErrorCode.gpsTooInaccurate =>
    'Your GPS signal is too weak to claim territory. Move near a window or '
        'step outside and try again.',
  ApiErrorCode.implausibleTravel =>
    "You've covered a lot of ground since your last workout. Give it a few "
        'minutes and try again.',
  ApiErrorCode.mockedLocationRejected =>
    "Mock locations can't claim territory. Turn off any GPS-spoofing app and "
        'try again.',
  ApiErrorCode.rateLimited =>
    "You've hit today's workout limit. Rest up and come back tomorrow.",
  ApiErrorCode.sessionExpired ||
  ApiErrorCode.unknownSession ||
  ApiErrorCode.sessionAlreadyUsed =>
    'That workout session has ended. Start a new one to keep training.',
  ApiErrorCode.timelineOutOfWindow ||
  ApiErrorCode.configVersionMismatch =>
    "We couldn't verify the timing of that set. Start a new session and go "
        'again.',
  ApiErrorCode.sessionContextMismatch =>
    'You moved too far from where you started. Start a new session where '
        'you are.',
  ApiErrorCode.evidenceMalformed || ApiErrorCode.scoringFailed =>
    "We couldn't verify that set. Keep your whole body in frame and try "
        'again.',
  ApiErrorCode.notComplete => 'Not done yet — keep going!',
  ApiErrorCode.alreadyClaimed =>
    "You've already claimed today's reward. New challenge tomorrow.",
  ApiErrorCode.unauthenticated =>
    "You're signed out. Restart the app to sign back in.",
  ApiErrorCode.bboxTooLarge => 'Zoom in a little to load territory.',
  _ when e.statusCode == 0 =>
    "Can't reach RepRush right now. Check your connection and try again.",
  _ => 'Something went wrong. Please try again.',
};

/// True when [error] means the active session can no longer be submitted, so
/// the client should drop it and let the athlete start fresh. A network blip
/// (status 0) is NOT one of these — the session survives and Finish can retry.
bool endsSession(Object error) =>
    error is ApiException &&
    const {
      ApiErrorCode.sessionExpired,
      ApiErrorCode.unknownSession,
      ApiErrorCode.sessionAlreadyUsed,
      ApiErrorCode.timelineOutOfWindow,
      ApiErrorCode.configVersionMismatch,
      ApiErrorCode.sessionContextMismatch,
    }.contains(error.code);
