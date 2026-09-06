/// Threshold resolution — turns a movement's rest-relative offsets plus a set's
/// own calibration into the absolute numbers the scorer and the trace cross-check
/// both need (docs/api-contract.md §Versioned calibration).
///
///     threshold = calibration.restSignal + offset
///
/// Offsets are never absolute angles (A-19): a 2D joint angle depends on viewing
/// angle and body proportions, so the athlete's own rest pose is the reference.

import type { Direction, MeasurementType, Unit } from "./schema.ts";

/** Trace tolerance — api-contract.md §"What the server can actually verify". */
export const TRACE_TOLERANCE_DEG = 15;
export const TRACE_TOLERANCE_RATIO = 0.15;

export interface MovementRow {
  id: string;
  family: string;
  tier: number;
  measurementType: MeasurementType;
  difficulty: number;
  holdBandLow: number | null;
  holdBandHigh: number | null;
}

export interface OffsetRow {
  movementId: string;
  enterPeakOffset: number;
  enterRestOffset: number;
  romTargetOffset: number;
  unit: Unit;
  direction: Direction;
}

/** Everything the scorer needs that is keyed by config version. */
export interface Catalogue {
  version: string;
  movements: Map<string, MovementRow>;
  offsets: Map<string, OffsetRow>;
}

export interface HoldBand {
  low: number;
  high: number;
  centre: number;
  halfWidth: number;
}

export interface ResolvedThresholds {
  movement: MovementRow;
  enterPeak: number;
  enterRest: number;
  romTarget: number;
  unit: Unit;
  direction: Direction;
  /** 15 for degrees, 0.15 for ratio signals. */
  tolerance: number;
  /** Non-null exactly for `holdTime` movements. */
  holdBand: HoldBand | null;
}

export class CatalogueError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = "CatalogueError";
    this.code = code;
  }
}

export function toleranceFor(unit: Unit): number {
  return unit === "ratio" ? TRACE_TOLERANCE_RATIO : TRACE_TOLERANCE_DEG;
}

/**
 * Resolves a movement's thresholds against one set's calibrated rest signal.
 *
 * Throws [CatalogueError] with `UNKNOWN_MOVEMENT` when the id is not in the
 * catalogue at all, and `CONFIG_MISSING_OFFSETS` when the movement exists but
 * has no offsets in the session's bound version — the latter is a seeding bug,
 * not a client error, and is worth distinguishing in the logs.
 */
export function resolveThresholds(
  catalogue: Catalogue,
  movementId: string,
  restSignal: number,
): ResolvedThresholds {
  const movement = catalogue.movements.get(movementId);
  if (!movement) {
    throw new CatalogueError("UNKNOWN_MOVEMENT", `no movement '${movementId}' in the catalogue`);
  }
  const offsets = catalogue.offsets.get(movementId);
  if (!offsets) {
    throw new CatalogueError(
      "CONFIG_MISSING_OFFSETS",
      `movement '${movementId}' has no offsets in config version '${catalogue.version}'`,
    );
  }

  // Hold mechanics have no state machine, so their offsets are placeholders and
  // the in-form band on the movement row is the only thing that matters.
  const isHold = movement.measurementType === "holdTime";
  const holdBand = isHold && movement.holdBandLow !== null && movement.holdBandHigh !== null
    ? {
      low: movement.holdBandLow,
      high: movement.holdBandHigh,
      centre: (movement.holdBandLow + movement.holdBandHigh) / 2,
      halfWidth: (movement.holdBandHigh - movement.holdBandLow) / 2,
    }
    : null;

  return {
    movement,
    enterPeak: restSignal + offsets.enterPeakOffset,
    enterRest: restSignal + offsets.enterRestOffset,
    romTarget: restSignal + offsets.romTargetOffset,
    unit: offsets.unit,
    direction: offsets.direction,
    tolerance: toleranceFor(offsets.unit),
    holdBand,
  };
}

/**
 * True when the direction means the signal falls as the athlete moves into the
 * hard position (squat, push-up, pull-up). A pull-up starts extended and flexes
 * upward, so up/down is ambiguous across movements — REST and PEAK are not
 * "high" and "low".
 */
export function isDecreasing(direction: Direction): boolean {
  return direction === "decreasing";
}

/**
 * Which of two signal values is the more extreme one, for a given direction.
 * Used by the trace cross-check to take the right end of a window.
 */
export function moreExtreme(a: number, b: number, direction: Direction): number {
  return isDecreasing(direction) ? Math.min(a, b) : Math.max(a, b);
}

/** True when `value` is at least as extreme as `reference`. */
export function atLeastAsExtreme(
  value: number,
  reference: number,
  direction: Direction,
): boolean {
  return isDecreasing(direction) ? value <= reference : value >= reference;
}
