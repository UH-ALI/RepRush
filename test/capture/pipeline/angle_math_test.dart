/// Unit tests for the hip-knee-ankle angle — pure arithmetic, no mocking.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:reprush/features/capture/pipeline/angle_math.dart';
import 'package:reprush/features/capture/pipeline/types.dart';

Lm lm(double x, double y) => (x: x, y: y, likelihood: 1);

void main() {
  final knee = lm(0, 0);

  test('a straight line reads 180°', () {
    // hip ← knee → ankle on one line, opposite directions.
    expect(kneeAngle(lm(-100, 0), knee, lm(100, 0)), closeTo(180, 1e-9));
  });

  test('a right angle reads 90°', () {
    expect(kneeAngle(lm(0, -100), knee, lm(100, 0)), closeTo(90, 1e-9));
  });

  test('an acute angle reads 45°', () {
    // ankle along the 45° diagonal from the knee.
    final ankle = lm(100, 100);
    expect(kneeAngle(lm(100, 0), knee, ankle), closeTo(45, 1e-9));
  });

  test('a known squat triangle reads ~80°', () {
    // thigh straight right; shin 80° below it.
    final rad = 80 * math.pi / 180;
    final ankle = lm(100 * math.cos(rad), 100 * math.sin(rad));
    expect(kneeAngle(lm(100, 0), knee, ankle), closeTo(80, 1e-6));
  });

  test('reflex readings are normalised to 0–180', () {
    // 270° the long way around is 90° the short way.
    expect(kneeAngle(lm(0, -100), knee, lm(-100, 0)), closeTo(90, 1e-9));
  });
}
