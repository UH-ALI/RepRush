/// Pipeline boundary types — plain Dart only (roles.md A, purity rule):
/// no Flutter, no plugins, no `dart:ui`. Landmarks in, Evidence out.
///
/// Ownership: A.
library;

/// One landmark: x/y in rotated image space plus in-frame visibility
/// (ML Kit `likelihood` — how clearly the landmark is seen).
typedef Lm = ({double x, double y, double likelihood});

/// One inference frame at the pipeline boundary. Keys are landmark names
/// (`"leftHip"`, `"rightKnee"`, …) — never ML Kit enum types.
class LandmarkFrame {
  const LandmarkFrame({
    required this.landmarks,
    required this.timestampMs,
    this.imageWidth,
    this.imageHeight,
  });

  final Map<String, Lm> landmarks;
  final int timestampMs;

  /// Rotated image dimensions, same space as the landmarks. Null when the
  /// source is unknown (synthetic fixtures) — the selector's frame-bounds
  /// check is skipped then.
  final double? imageWidth;
  final double? imageHeight;
}

/// The pipeline's mirror of Flutter's `LiveFeedbackState` — the pipeline
/// never imports the Flutter side (purity rule).
enum FeedbackLevel { green, amber, red }
