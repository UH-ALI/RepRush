/// Hold conversion — the `holdTime` mechanic (docs/api-contract.md §Holds).
///
/// A hold has no state machine at all. Track A accrues time while the in-form
/// predicate holds and emits `holdSegments`; the seconds are already form-gated
/// before they reach here, so a sagging plank has stopped earning upstream.
///
/// This file settles the open decision flagged at api-contract.md:133 — "is
/// 3 × 20 s worth the same as 1 × 60 s?" No. Segments under MIN_HOLD_SEGMENT_MS
/// do not count at all, and the qualifying total is discounted by segment count,
/// so resting is not free. Both constants are Day-4 sanity-check candidates: if
/// plank ends up the best points-per-minute in the game, this is where B fixes it.

import type { EvidenceHoldSegment } from "../evidence/schema.ts";
import type { HoldBand } from "../evidence/thresholds.ts";
import { clamp } from "./rom.ts";
import { baseFormFactor, confScore, FORM_FLOOR } from "./form.ts";
import { mean } from "./tempo.ts";

/** Shorter than this and the segment is a micro-break wearing a hold's clothes. */
export const MIN_HOLD_SEGMENT_MS = 5000;

/** Each extra segment costs this fraction of the total, multiplicatively. */
export const HOLD_SEGMENT_DISCOUNT = 0.10;

/** One rep-equivalent per 3 seconds (requirements.md §4). */
export const HOLD_SECONDS_PER_REP = 3;

export interface HoldResult {
  segmentsTotal: number;
  qualifyingSegments: number;
  qualifyingMs: number;
  /** 1 / (1 + HOLD_SEGMENT_DISCOUNT × (segments − 1)). */
  discount: number;
  /** How central the hold was inside the in-form band. */
  bandScore: number;
  confScore: number;
  formFactor: number;
  /** Seconds / 3, after the segment discount. Multiplies into RepScore. */
  repEquivalents: number;
}

/**
 * Scores a hold set. `band` comes from `movements.hold_band_low/high` via
 * [resolveThresholds] — plank is 160–185, so centre 172.5 and half-width 12.5.
 *
 * `bandScore` plays the role `romScore` plays for reps: the segment already
 * passed the in-form gate to exist, and this grades how comfortably inside the
 * band it sat. Keeping the same 0.60/0.40 shape as the rep formula means one
 * `baseFormFactor` covers both measurement types.
 */
export function scoreHold(
  segments: EvidenceHoldSegment[],
  band: HoldBand,
): HoldResult {
  const qualifying = segments.filter(
    (s) => s.tEndMs - s.tStartMs >= MIN_HOLD_SEGMENT_MS,
  );
  const qualifyingMs = qualifying.reduce((acc, s) => acc + (s.tEndMs - s.tStartMs), 0);

  const discount = 1 / (1 + HOLD_SEGMENT_DISCOUNT * Math.max(0, qualifying.length - 1));

  if (qualifying.length === 0) {
    return {
      segmentsTotal: segments.length,
      qualifyingSegments: 0,
      qualifyingMs: 0,
      discount: 1,
      bandScore: 0,
      confScore: 0,
      formFactor: FORM_FLOOR,
      repEquivalents: 0,
    };
  }

  const meanSignal = mean(qualifying.map((s) => s.meanSignal)) ?? band.centre;
  const meanConf = mean(qualifying.map((s) => s.confMean)) ?? 0;

  const bandScore = band.halfWidth > 0
    ? clamp(1 - Math.abs(meanSignal - band.centre) / band.halfWidth, 0, 1)
    : 1;
  const conf = confScore(meanConf);

  const seconds = qualifyingMs / 1000;
  return {
    segmentsTotal: segments.length,
    qualifyingSegments: qualifying.length,
    qualifyingMs,
    discount,
    bandScore,
    confScore: conf,
    formFactor: baseFormFactor(bandScore, conf),
    repEquivalents: (seconds / HOLD_SECONDS_PER_REP) * discount,
  };
}
