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
  const LandmarkFrame({required this.landmarks, required this.timestampMs});

  final Map<String, Lm> landmarks;
  final int timestampMs;
}

/// The pipeline's mirror of Flutter's `LiveFeedbackState` — the pipeline
/// never imports the Flutter side (purity rule).
enum FeedbackLevel { green, amber, red }
