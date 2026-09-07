/// Movement configs — per-movement constants (roles.md A-7; threshold table
/// in api-contract.md §evidence). Offsets are RELATIVE to the calibrated
/// rest signal, never absolute angles (A-19).
///
/// Ownership: A. Purity rule: plain Dart only.
library;

/// A 3-point joint chain — the landmarks a movement's angle signal is
/// measured on, expressed as landmark-name suffixes so every layer derives
/// its own representation (string keys in the pipeline, enum values in the
/// camera layer) from one source of truth.
enum JointChain {
  /// hip → knee → ankle (squat family).
  leg('Hip', 'Knee', 'Ankle'),

  /// shoulder → elbow → wrist (push-up / pull-up family).
  arm('Shoulder', 'Elbow', 'Wrist');

  const JointChain(this.proximal, this.vertex, this.distal);

  /// The chain's anchor landmark (hip / shoulder).
  final String proximal;

  /// The angle vertex (knee / elbow).
  final String vertex;

  /// The chain's far end (ankle / wrist).
  final String distal;

  /// Landmark keys on both sides in left-then-right order — e.g.
  /// `['leftHip', 'leftKnee', 'leftAnkle', 'rightHip', …]` for the leg
  /// chain. Diagnostics tooling uses this; hot paths interpolate keys
  /// directly.
  List<String> get landmarkKeys => [
        for (final side in const ['left', 'right']) ...[
          '$side$proximal',
          '$side$vertex',
          '$side$distal',
        ],
      ];
}

/// Per-movement coaching vocabulary — the engine picks cues by phase, the
/// movement supplies the wording. Defaults are the squat-proven strings;
/// movements whose phrasing differs (arm chains) override only what they
/// need.
class FeedbackCues {
  const FeedbackCues({
    this.calibrating = 'Hold still — calibrating',
    this.ready = 'Ready',
    this.descending = 'Go lower',
    this.depthReached = 'Good depth',
    this.ascending = 'Stand tall',
    this.repCounted = 'Rep counted',
    this.shallowReturn = 'Not counted — go lower next rep',
    this.trackingLost = 'Tracking lost',
    this.retryTooFewSamples =
        'Not enough steady frames yet — hold your position',
    this.retryUnstableRest = 'Too much movement — stand still while we retry',
    this.retryImplausibleRest =
        'Stand side-on, straighten your legs, keep full body in frame — retrying',
  });

  /// The squat-proven default vocabulary.
  static const FeedbackCues standard = FeedbackCues();

  final String calibrating;
  final String ready;
  final String descending;
  final String depthReached;
  final String ascending;
  final String repCounted;
  final String shallowReturn;
  final String trackingLost;
  final String retryTooFewSamples;
  final String retryUnstableRest;
  final String retryImplausibleRest;
}

/// Threshold offsets applied to the calibrated rest signal. For squat
/// (rest ≈ 175°): startDescent 163°, enterPeak 110°, enterRest 150°,
/// romTarget 80°.
class MovementConfig {
  const MovementConfig({
    required this.id,
    required this.startDescentOffset,
    required this.enterPeakOffset,
    required this.enterRestOffset,
    required this.romTargetOffset,
    required this.decreasing,
    this.chain = JointChain.leg,
    this.cues = FeedbackCues.standard,
  });

  final String id;

  /// The 3-point joint chain the angle signal is measured on.
  final JointChain chain;

  /// Coaching vocabulary for this movement.
  final FeedbackCues cues;

  /// Gates REST → DESCENDING — fires early so amber "Go lower" shows while
  /// the athlete can still correct. Must sit between rest and enterRest.
  final double startDescentOffset;

  /// Gates DESCENDING → DEPTH_REACHED — the valid-depth gate.
  final double enterPeakOffset;

  /// Gates the return to REST (and counts the rep on the way up).
  final double enterRestOffset;

  /// Full ROM grade target (scoring milestone — carried, not consumed yet).
  final double romTargetOffset;

  /// True when the signal drops at peak (squat); false would mean it rises.
  final bool decreasing;
}

const squatConfig = MovementConfig(
  id: 'squat',
  startDescentOffset: -12.0,
  enterPeakOffset: -65.0,
  enterRestOffset: -25.0,
  romTargetOffset: -95.0,
  decreasing: true,
);

// ---------------------------------------------------------------------------
// Push-up config — elbow chain (shoulder → elbow → wrist), bilateral.
// Camera placement: athlete horizontal on floor, camera to the side at
// ~hip height so the full arm extension and chest-to-floor depth are visible.
//
// Threshold rationale (UNTUNED — replace after measuring a real recorded set):
//   Rest ≈ 160° (arms nearly straight at top, slight natural bend).
//   startDescentOffset  −8 → fires at ≈152° (arms start to bend)
//   enterPeakOffset    −70 → fires at ≈ 90° (elbow at roughly parallel-depth)
//   enterRestOffset    −20 → rep counted on the way back up past ≈140°
//   romTargetOffset    −90 → full-ROM grade target ≈ 70° (chest near floor)
// ---------------------------------------------------------------------------
const pushUpConfig = MovementConfig(
  id: 'push_up',
  chain: JointChain.arm,
  // UNTUNED — measured against a rest signal near 160°; replace with values
  // from a recorded set once real landmark data is available.
  startDescentOffset: -8.0,
  enterPeakOffset: -70.0,
  enterRestOffset: -20.0,
  romTargetOffset: -90.0,
  decreasing: true,
  cues: FeedbackCues(
    calibrating: 'Hold the top position — calibrating',
    ready: 'Ready',
    descending: 'Lower your chest',
    depthReached: 'Good depth',
    ascending: 'Push up',
    repCounted: 'Rep counted',
    shallowReturn: 'Not counted — go lower next rep',
    trackingLost: 'Tracking lost',
    retryTooFewSamples:
        'Not enough steady frames yet — hold the top position',
    retryUnstableRest: 'Too much movement — hold still at the top',
    retryImplausibleRest:
        'Lie flat, arms straight, camera to the side — retrying',
  ),
);
