/// Widget test for the capture entry point — the camera itself is never
/// touched: the controller is overridden to a deterministic problem state.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/data/capture_controller.dart';
import 'package:reprush/features/capture/data/capture_providers.dart';
import 'package:reprush/features/capture/ui/capture_preview_screen.dart';

class _DeniedCaptureController extends CaptureController {
  @override
  Future<void> start() async {
    state = const CaptureStatus(
      phase: CapturePhase.denied,
      message:
          'Camera access was denied. Allow the camera permission in system '
          'settings, then try again.',
    );
  }
}

void main() {
  testWidgets('denied camera access shows explanation and retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          captureControllerProvider.overrideWith(_DeniedCaptureController.new),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(height: 480, child: CapturePreviewScreen()),
          ),
        ),
      ),
    );
    await tester.pump();

    // N9: the problem is an icon + text + button, never colour alone.
    expect(find.textContaining('Camera access was denied'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_off), findsOneWidget);
  });
}
