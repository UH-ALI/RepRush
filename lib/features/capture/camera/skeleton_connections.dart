/// Skeleton connectivity for the 33 ML Kit pose landmarks (A-10 overlay).
library;

import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

/// One bone: a pair of connected landmark types.
typedef Bone = (PoseLandmarkType, PoseLandmarkType);

/// The bone list drawn by the overlay, mirroring the standard pose-landmark
/// connectivity.
const List<Bone> skeletonConnections = [
  // Head.
  (PoseLandmarkType.nose, PoseLandmarkType.leftEyeInner),
  (PoseLandmarkType.leftEyeInner, PoseLandmarkType.leftEye),
  (PoseLandmarkType.leftEye, PoseLandmarkType.leftEyeOuter),
  (PoseLandmarkType.leftEyeOuter, PoseLandmarkType.leftEar),
  (PoseLandmarkType.nose, PoseLandmarkType.rightEyeInner),
  (PoseLandmarkType.rightEyeInner, PoseLandmarkType.rightEye),
  (PoseLandmarkType.rightEye, PoseLandmarkType.rightEyeOuter),
  (PoseLandmarkType.rightEyeOuter, PoseLandmarkType.rightEar),
  // Torso.
  (PoseLandmarkType.leftEar, PoseLandmarkType.leftShoulder),
  (PoseLandmarkType.rightEar, PoseLandmarkType.rightShoulder),
  (PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder),
  (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip),
  (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip),
  (PoseLandmarkType.leftHip, PoseLandmarkType.rightHip),
  // Arms.
  (PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow),
  (PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist),
  (PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow),
  (PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist),
  // Hands.
  (PoseLandmarkType.leftWrist, PoseLandmarkType.leftThumb),
  (PoseLandmarkType.leftWrist, PoseLandmarkType.leftIndex),
  (PoseLandmarkType.leftWrist, PoseLandmarkType.leftPinky),
  (PoseLandmarkType.rightWrist, PoseLandmarkType.rightThumb),
  (PoseLandmarkType.rightWrist, PoseLandmarkType.rightIndex),
  (PoseLandmarkType.rightWrist, PoseLandmarkType.rightPinky),
  // Legs.
  (PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee),
  (PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle),
  (PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee),
  (PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle),
  // Feet.
  (PoseLandmarkType.leftAnkle, PoseLandmarkType.leftHeel),
  (PoseLandmarkType.leftHeel, PoseLandmarkType.leftFootIndex),
  (PoseLandmarkType.leftAnkle, PoseLandmarkType.leftFootIndex),
  (PoseLandmarkType.rightAnkle, PoseLandmarkType.rightHeel),
  (PoseLandmarkType.rightHeel, PoseLandmarkType.rightFootIndex),
  (PoseLandmarkType.rightAnkle, PoseLandmarkType.rightFootIndex),
];
