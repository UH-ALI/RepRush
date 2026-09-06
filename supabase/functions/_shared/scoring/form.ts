/// formFactor — the [0.6, 1.0] grade on a rep, plus the two multiplicative
/// penalties that sit on top of it (docs/api-contract.md §formFactor).
///
/// The floor matters more than the ceiling: good lighting is never rewarded, but
/// poor lighting degrades gracefully instead of scaling from zero. B7 requires
/// low-confidence reps to count-but-be-penalised, and this is the mildest
/// reading of that which still satisfies it.

import { clamp, romScore } from "./rom.ts";

/** confScore saturates here — at or above this, confidence contributes 1.0. */
export const CONF_REFERENCE = 0.70;

export const FORM_FLOOR = 0.60;
export const FORM_HEADROOM = 0.40;
export const ROM_WEIGHT = 0.60;
export const CONF_WEIGHT = 0.40;

// -- B18 · swing / kip penalty ----------------------------------------------
// Kipping makes a pull-up materially easier, and horizontal hip displacement
// across a rep is directly measurable. Below KIP_FREE nothing is docked; at
// KIP_FULL the maximum dock applies. The threshold is deliberately generous —
// requirements.md §10 warns that too tight docks honest reps, and it is meant to
// be tuned against a real kipping set on Day 5.
export const KIP_FREE = 0.15;
export const KIP_FULL = 0.40;
export const KIP_MAX_DOCK = 0.35;

// -- B16 · pull-up second signal -------------------------------------------
// The bar is never detected — the wrist landmarks ARE the bar. At the top of a
// strict pull-up the wrist collapses toward the shoulder line, so a large
// shoulder-to-wrist vertical distance means the chin never really cleared it.
export const PULLUP_DY_LIMIT = 0.25;
export const PULLUP_UNCONFIRMED_FACTOR = 0.75;

export function confScore(confMean: number): number {
  return clamp(confMean / CONF_REFERENCE, 0, 1);
}

/**
 *     formFactor = 0.60 + 0.40 × ( 0.60 × romScore + 0.40 × confScore )
 *
 * Lands in [0.6, 1.0] by construction — the two weights sum to 1 and both
 * inputs are clamped to [0, 1], so this cannot escape the range on its own.
 * Penalties are applied on top by [repFormFactor] and deliberately CAN take the
 * result below 0.6; see the note there.
 */
export function baseFormFactor(rom: number, conf: number): number {
  return FORM_FLOOR + FORM_HEADROOM * (ROM_WEIGHT * rom + CONF_WEIGHT * conf);
}

/**
 * B18 dock for horizontal hip drift, as a fraction in [0, KIP_MAX_DOCK].
 * Undefined (the signal is optional and Track A does not emit it for squat)
 * docks nothing — an absent measurement is not evidence of a kip.
 */
export function kipDock(hipDriftNorm: number | undefined): number {
  if (hipDriftNorm === undefined) return 0;
  return clamp((hipDriftNorm - KIP_FREE) / (KIP_FULL - KIP_FREE), 0, 1) * KIP_MAX_DOCK;
}

/** B16 — true when the pull-up's confirming signal says the rep did not reach. */
export function pullUpUnconfirmed(
  movementId: string,
  shoulderWristDyNorm: number | undefined,
): boolean {
  if (movementId !== "pull_up") return false;
  return shoulderWristDyNorm !== undefined && shoulderWristDyNorm > PULLUP_DY_LIMIT;
}

export interface RepFormResult {
  romScore: number;
  confScore: number;
  /** The grade before penalties — what the summary screen shows as "form". */
  base: number;
  kipDock: number;
  unconfirmed: boolean;
  /** What actually multiplies into RepScore. */
  formFactor: number;
}

/**
 * Full per-rep form grade. Both penalties are multiplicative on top of the base
 * (api-contract.md:123), and the result is re-clamped to the contract range so
 * no combination of penalties can push formFactor below the floor.
 */
export function repFormFactor(
  movementId: string,
  peakExtreme: number,
  enterPeak: number,
  romTarget: number,
  confMean: number,
  hipDriftNorm: number | undefined,
  shoulderWristDyNorm: number | undefined,
): RepFormResult {
  const rom = romScore(peakExtreme, enterPeak, romTarget);
  const conf = confScore(confMean);
  const base = baseFormFactor(rom, conf);

  const dock = kipDock(hipDriftNorm);
  const unconfirmed = pullUpUnconfirmed(movementId, shoulderWristDyNorm);

  // Penalties are NOT re-clamped to the [0.6, 1.0] contract range, and that is a
  // deliberate reading of api-contract.md:123 — "Lands in [0.6, 1.0] ... Penalties
  // apply multiplicatively on top." The range describes the base formula; the
  // penalties sit outside it. Re-clamping at 0.6 would make B18 a no-op for
  // anyone whose base already sits near the floor, i.e. kipping would be free
  // exactly for the shallow reps it is meant to punish. The absolute floor is 0:
  // the worst case is 0.6 × (1 − 0.35) × 0.75 ≈ 0.29, never negative.
  let formFactor = base * (1 - dock);
  if (unconfirmed) formFactor *= PULLUP_UNCONFIRMED_FACTOR;
  formFactor = clamp(formFactor, 0, 1);

  return { romScore: rom, confScore: conf, base, kipDock: dock, unconfirmed, formFactor };
}

/** Set-level formFactor is the mean across reps (api-contract.md:127). */
export function setFormFactor(repFormFactors: number[]): number {
  if (repFormFactors.length === 0) return FORM_FLOOR;
  const total = repFormFactors.reduce((a, b) => a + b, 0);
  return total / repFormFactors.length;
}
