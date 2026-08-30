/// Skeleton overlay — joints and bones mapped onto the centre-cropped camera
/// preview (roles.md A-10), with visibility-aware feedback colours driven by
/// the counting pipeline (milestone spec §11).
///
/// Rendering tiers:
/// 1. Active-side hip/knee/ankle above threshold → feedback colour.
/// 2. Other landmarks above threshold → brand green.
/// 3. Any landmark below threshold → dimmed to near-invisibility.
/// No usable chain → the controller publishes a null frame → nothing paints.
///
/// Ownership: A.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/features/capture/camera/coordinates.dart';
import 'package:reprush/features/capture/camera/skeleton_connections.dart';
import 'package:reprush/features/capture/data/capture_controller.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

/// Draws the skeleton for the latest [frame]. Landmarks live in rotated
/// image space; [imageToViewPoint] applies the same centre-crop transform
/// the `CameraPreview` uses, which is what keeps bones on the body.
class SkeletonOverlay extends CustomPainter {
  SkeletonOverlay({required this.frame});

  final PoseFrame? frame;

  /// Matches the side-selector floor — a landmark below this is "barely
  /// seen" and must not look tracked.
  static const double _visibilityThreshold = 0.5;
  static const double _dimOpacity = 0.15;

  @override
  void paint(Canvas canvas, Size size) {
    final frame = this.frame;
    if (frame == null || size.isEmpty || frame.imageSize.isEmpty) return;

    final feedback = frame.feedback;
    final activeLandmarks = frame.activeSideLandmarks ?? const {};
    final visibility = frame.landmarkVisibility ?? const {};

    final feedbackColor = switch (feedback?.level) {
      FeedbackLevel.green => RepRushTokens.brand,
      FeedbackLevel.amber => RepRushTokens.feedbackAmber,
      FeedbackLevel.red => RepRushTokens.feedbackRed,
      null => RepRushTokens.brand,
    };

    // --- Bones: two-pass (dark outline + white core) stays legible on any
    // camera background; dimmed bones skip the outline pass.
    for (final (from, to) in skeletonConnections) {
      final a = frame.points[from];
      final b = frame.points[to];
      if (a == null || b == null) continue;
      final start = imageToViewPoint(a, frame.imageSize, size);
      final end = imageToViewPoint(b, frame.imageSize, size);
      final dim =
          (visibility[from] ?? 0.0) < _visibilityThreshold ||
          (visibility[to] ?? 0.0) < _visibilityThreshold;
      if (!dim) {
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = const Color(0xCC000000)
            ..strokeWidth = 5
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round,
        );
      }
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, dim ? _dimOpacity : 0.9)
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }

    // --- Joints: feedback colour on the counted chain, brand green
    // elsewhere, near-invisible below the visibility floor.
    for (final entry in frame.points.entries) {
      final point = imageToViewPoint(entry.value, frame.imageSize, size);
      final visible = (visibility[entry.key] ?? 1.0) >= _visibilityThreshold;
      final color = !visible
          ? RepRushTokens.brand.withValues(alpha: _dimOpacity)
          : activeLandmarks.contains(entry.key)
          ? feedbackColor
          : RepRushTokens.brand;
      canvas.drawCircle(point, RepRushTokens.spaceXs, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(SkeletonOverlay oldDelegate) => oldDelegate.frame != frame;
}
