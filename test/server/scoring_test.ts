/// The correctness anchor for the scoring engine.
///
/// WHY THIS FILE IS DIFFERENT FROM THE GOLDENS
/// `golden_test.ts` compares against numbers the implementation produced, so it
/// can only tell you the implementation stopped changing. This file asserts
/// numbers that came from somewhere else — a table in docs/api-contract.md, a
/// formula in docs/requirements.md, or arithmetic done by hand on a calculator —
/// so it is the only place in the suite that can catch the engine being
/// confidently wrong.
///
/// Every assertion below names the line of the document it came from. If a
/// document changes and this file does not, that is the bug.

import type {
  Evidence,
  EvidenceRep,
  EvidenceSet,
} from "../../supabase/functions/_shared/evidence/schema.ts";
import {
  baseFormFactor,
  CONF_REFERENCE,
  confScore,
  FORM_FLOOR,
  KIP_FREE,
  KIP_FULL,
  KIP_MAX_DOCK,
  kipDock,
  PULLUP_DY_LIMIT,
  PULLUP_UNCONFIRMED_FACTOR,
  pullUpUnconfirmed,
  repFormFactor,
  setFormFactor,
} from "../../supabase/functions/_shared/scoring/form.ts";
import { romScore } from "../../supabase/functions/_shared/scoring/rom.ts";
import {
  CADENCE_GAP_FLOOR_MS,
  CV_HEALTHY,
  FATIGUE_SLOPE_HEALTHY,
  IMPOSSIBLE_CYCLE_MS,
  MIN_REPS_FOR_FATIGUE,
  MIN_REPS_FOR_VARIANCE,
  TEMPO_FLOOR,
  tempoFromReps,
  UNIFORMITY_MAX_PENALTY,
} from "../../supabase/functions/_shared/scoring/tempo.ts";
import {
  HOLD_SECONDS_PER_REP,
  HOLD_SEGMENT_DISCOUNT,
  MIN_HOLD_SEGMENT_MS,
  scoreHold,
} from "../../supabase/functions/_shared/scoring/holds.ts";
import {
  applyDailyCap,
  capSet,
  dailyCapApplied,
  DAY_FULL_UNTIL,
  DAY_HALF_RATE,
  DAY_HALF_UNTIL,
  DAY_TAIL_RATE,
  PER_SET_CAP,
} from "../../supabase/functions/_shared/scoring/caps.ts";
import { scoreEvidence, scoreSet } from "../../supabase/functions/_shared/scoring/score.ts";
import { MOVEMENT_NOT_UNLOCKED, SET_CAPPED } from "../../supabase/functions/_shared/flags.ts";
import type { HoldBand } from "../../supabase/functions/_shared/evidence/thresholds.ts";
import { testCatalogue } from "./tools/catalogue.ts";
import { CONFIG_VERSION } from "./tools/fixtures.ts";
import { near, ok, strictEqual, test } from "./_harness.ts";

// ---------------------------------------------------------------------------
// romScore — docs/api-contract.md:109-114
// ---------------------------------------------------------------------------
//
// The table in the contract is the specification. `enterPeak` 110 / `romTarget`
// 80 are the squat's offsets (-65 / -95) resolved against a rest signal of 175;
// 90 / 55 are the pull-up's (-85 / -120) against the same rest.

test("romScore · api-contract.md:111 — squat, peakExtreme 95 → 0.50", () => {
  near(romScore(95, 110, 80), 0.5, 1e-12);
});

test("romScore · api-contract.md:112 — squat, peakExtreme 78 → 1.07, capped at 1.00", () => {
  // (78−110)/(80−110) = 32/30 = 1.0667. The cap is the point: depth past the
  // target earns nothing extra, so a hypermobile athlete cannot out-score a
  // well-calibrated one by going deeper.
  strictEqual(romScore(78, 110, 80), 1);
});

test("romScore · api-contract.md:113 — pull-up, peakExtreme 52.8 → 1.06, capped at 1.00", () => {
  strictEqual(romScore(52.8, 90, 55), 1);
});

test("romScore · api-contract.md:114 — jumping jack, peakExtreme 1.45 → 0.63", () => {
  // The contract prints 0.63; the exact value is 0.25/0.40 = 0.625. Asserting
  // 0.63 would bake a rounding decision into the engine, and the difference
  // would then show up in every downstream total.
  near(romScore(1.45, 1.2, 1.6), 0.625, 1e-9);
});

test("romScore · one formula covers both directions, because the signs cancel", () => {
  // An increasing signal (jumping jack, ratio) and a decreasing one (squat, deg)
  // both yield a positive fraction from the same expression.
  const decreasing = romScore(95, 110, 80);
  const increasing = romScore(1.45, 1.2, 1.6);
  near(decreasing, 0.5, 1e-12);
  near(increasing, 0.625, 1e-9);
});

test("romScore · at enterPeak the grade is 0, and shallower than it stays 0", () => {
  // A rep that only just crossed the gate is a real rep (Track A counted it)
  // with no depth credit. It must never go negative.
  //
  // The first case is `0 / -30`, which IEEE makes `-0` rather than `0`. That is
  // asserted with strictEqual on purpose: it uses Object.is, so this test fails
  // on a negative zero even though `-0` prints as `0`. Letting one through would
  // surface later as an inexplicable golden diff, since JSON round-trips `-0` as
  // `+0`. `clamp` normalises it.
  strictEqual(romScore(110, 110, 80), 0);
  ok(Object.is(romScore(110, 110, 80), 0), "must be +0, not -0");
  strictEqual(romScore(140, 110, 80), 0);
});

test("romScore · romTarget equal to enterPeak is a seeding bug, read as 0 not a windfall", () => {
  // Without the guard this is 0/0 = NaN, which would propagate into formFactor
  // and then into the ledger.
  strictEqual(romScore(100, 110, 110), 0);
});

// ---------------------------------------------------------------------------
// formFactor — docs/api-contract.md:116-127
// ---------------------------------------------------------------------------

test("confScore · api-contract.md:119 — clamp(confMean / 0.70, 0, 1)", () => {
  strictEqual(confScore(CONF_REFERENCE), 1);
  // "Good lighting is never rewarded": anything at or above the reference
  // contributes exactly 1.0 and never bites.
  strictEqual(confScore(0.95), 1);
  strictEqual(confScore(1), 1);
  // Below it, linear — "poor lighting degrades gracefully instead of scaling
  // from zero" (api-contract.md:125).
  near(confScore(0.35), 0.5, 1e-12);
  strictEqual(confScore(0), 0);
});

test("formFactor · api-contract.md:120 — lands in [0.6, 1.0] at both corners", () => {
  strictEqual(baseFormFactor(0, 0), FORM_FLOOR);
  near(baseFormFactor(1, 1), 1, 1e-12);
});

test("formFactor · api-contract.md:120 — the 0.60/0.40 blend, worked by hand", () => {
  // romScore 5/6 (a squat peaking at 85 against enterPeak 110 / romTarget 80),
  // confScore 1. 0.60 + 0.40 × (0.60 × 5/6 + 0.40 × 1) = 0.60 + 0.40 × 0.90
  // = 0.96 — the number in squat_metronome's golden.
  near(baseFormFactor(5 / 6, 1), 0.96, 1e-12);
  // ROM carries 1.5x the weight of confidence, per ROM_WEIGHT/CONF_WEIGHT.
  const romOnly = baseFormFactor(1, 0);
  const confOnly = baseFormFactor(0, 1);
  near(romOnly, 0.84, 1e-12);
  near(confOnly, 0.76, 1e-12);
  ok(romOnly > confOnly, "ROM must weigh more than confidence");
});

test("setFormFactor · api-contract.md:127 — the mean across reps", () => {
  near(setFormFactor([0.8, 0.9, 1.0]), 0.9, 1e-12);
  // An empty set falls back to the floor rather than to NaN: a zero-rep set
  // scores nothing anyway, but the number still reaches the ledger row.
  strictEqual(setFormFactor([]), FORM_FLOOR);
});

test("kipDock · B18 — nothing below KIP_FREE, the full dock at KIP_FULL", () => {
  strictEqual(kipDock(KIP_FREE), 0);
  strictEqual(kipDock(0.05), 0);
  near(kipDock(KIP_FULL), KIP_MAX_DOCK, 1e-12);
  // Saturates: a larger kip cannot dock more than the maximum.
  near(kipDock(2.0), KIP_MAX_DOCK, 1e-12);
  // Linear in between: (0.275 − 0.15) / (0.40 − 0.15) = 0.5 → half the dock.
  near(kipDock((KIP_FREE + KIP_FULL) / 2), KIP_MAX_DOCK / 2, 1e-12);
});

test("kipDock · B18 — an absent signal docks nothing", () => {
  // hipDriftNorm is optional and Track A does not emit it for squat. An absent
  // measurement is not evidence of a kip.
  strictEqual(kipDock(undefined), 0);
});

test("pullUpUnconfirmed · B16 — strictly greater, and pull_up only", () => {
  strictEqual(pullUpUnconfirmed("pull_up", PULLUP_DY_LIMIT + 0.01), true);
  // `>` not `>=`: exactly at the limit is a confirmed rep.
  strictEqual(pullUpUnconfirmed("pull_up", PULLUP_DY_LIMIT), false);
  strictEqual(pullUpUnconfirmed("pull_up", undefined), false);
  // The signal means nothing for any other movement — a squat's wrist is not
  // near its shoulder at the bottom.
  strictEqual(pullUpUnconfirmed("squat", 0.9), false);
  strictEqual(pullUpUnconfirmed("wide_grip_pull_up", 0.9), false);
});

test("repFormFactor · api-contract.md:123 — penalties are NOT re-clamped to [0.6, 1.0]", () => {
  // The worst legal case: no depth, no confidence, a saturated kip and a failed
  // confirmation. 0.60 × (1 − 0.35) × 0.75 = 0.2925.
  const worst = repFormFactor("pull_up", 90, 90, 55, 0, KIP_FULL, PULLUP_DY_LIMIT + 0.1);
  near(worst.formFactor, FORM_FLOOR * (1 - KIP_MAX_DOCK) * PULLUP_UNCONFIRMED_FACTOR, 1e-9);
  ok(
    worst.formFactor < FORM_FLOOR,
    `formFactor ${worst.formFactor} was re-clamped to the contract floor — that would make ` +
      "B18 free for exactly the shallow reps it exists to punish",
  );
  ok(worst.formFactor >= 0, "the absolute floor is 0, never negative");
});

test("repFormFactor · the two penalties compose multiplicatively and independently", () => {
  const base = { rom: 1, conf: 1 };
  const clean = repFormFactor("pull_up", 55, 90, 55, base.conf, undefined, 0.1);
  const kipped = repFormFactor("pull_up", 55, 90, 55, base.conf, KIP_FULL, 0.1);
  const unconfirmed = repFormFactor("pull_up", 55, 90, 55, base.conf, undefined, 0.3);
  const both = repFormFactor("pull_up", 55, 90, 55, base.conf, KIP_FULL, 0.3);

  near(clean.formFactor, 1, 1e-12);
  near(kipped.formFactor, clean.formFactor * (1 - KIP_MAX_DOCK), 1e-12);
  near(unconfirmed.formFactor, clean.formFactor * PULLUP_UNCONFIRMED_FACTOR, 1e-12);
  near(both.formFactor, kipped.formFactor * PULLUP_UNCONFIRMED_FACTOR, 1e-12);
  // romScore 1 for a pull-up at peakExtreme 55: (55−90)/(55−90) = 1 exactly.
  strictEqual(clean.romScore, 1);
});

// ---------------------------------------------------------------------------
// tempoFactor — docs/requirements.md:165
// ---------------------------------------------------------------------------

/** Builds reps with the given cycle lengths, separated by `gapMs`. */
function cycles(lengths: readonly number[], gapMs = 600): EvidenceRep[] {
  const reps: EvidenceRep[] = [];
  let cursor = 0;
  lengths.forEach((length, i) => {
    if (i > 0) cursor += gapMs;
    const tStartMs = cursor;
    const tEndMs = cursor + length;
    reps.push({
      i,
      tStartMs,
      tEndMs,
      restExtreme: 175,
      peakExtreme: 82,
      confMean: 0.9,
      confMin: 0.85,
      concentricMs: Math.round(length * 0.45),
      eccentricMs: Math.round(length * 0.55),
    });
    cursor = tEndMs;
  });
  return reps;
}

test("tempoFactor · a metronome saturates the uniformity penalty at 0.65", () => {
  const tempo = tempoFromReps(cycles(new Array(8).fill(2000)));
  strictEqual(tempo.cycleCv, 0);
  near(tempo.uniformityPenalty, UNIFORMITY_MAX_PENALTY, 1e-12);
  near(tempo.tempoFactor, 1 - UNIFORMITY_MAX_PENALTY, 1e-12);
  strictEqual(tempo.tempoFactor, 0.65);
});

test("tempoFactor · the uniformity penalty ramps linearly to zero at CV_HEALTHY", () => {
  // Half the healthy cv should cost half the maximum penalty. Constructing that
  // signal exactly is fiddly, so this checks the two ends and monotonicity
  // instead: the ramp must never be a step.
  const flat = tempoFromReps(cycles(new Array(10).fill(2000)));
  near(flat.uniformityPenalty, UNIFORMITY_MAX_PENALTY, 1e-12);

  // Cycles spread over 1000..3000 in ten steps: cv ≈ 0.33, far above healthy.
  const spread = tempoFromReps(
    cycles([1000, 1250, 1500, 1750, 2000, 2250, 2500, 2750, 3000, 3250]),
  );
  strictEqual(spread.uniformityPenalty, 0);
  ok((spread.cycleCv ?? 0) > CV_HEALTHY, "this set should be comfortably above CV_HEALTHY");
  strictEqual(spread.tempoFactor, 1);
});

test("tempoFactor · below MIN_REPS_FOR_VARIANCE, cv is null and nothing is penalised", () => {
  const tempo = tempoFromReps(cycles(new Array(MIN_REPS_FOR_VARIANCE - 1).fill(2000)));
  strictEqual(tempo.cycleCv, null, "too few reps for spread to mean anything");
  strictEqual(tempo.uniformityPenalty, 0);
  // Four identical cycles look exactly like a bot, and are deliberately not
  // treated as one: absence of evidence is not evidence of a bot.
  strictEqual(tempo.tempoFactor, 1);
});

test("tempoFactor · at exactly MIN_REPS_FOR_VARIANCE, cv IS computed", () => {
  const tempo = tempoFromReps(cycles(new Array(MIN_REPS_FOR_VARIANCE).fill(2000)));
  strictEqual(tempo.cycleCv, 0);
  near(tempo.uniformityPenalty, UNIFORMITY_MAX_PENALTY, 1e-12);
});

test("tempoFactor · below MIN_REPS_FOR_FATIGUE the slope is null, not 1", () => {
  // The distinction matters: a null slope means "not measured", a slope of 1
  // means "measured and perfectly flat", and only the second is penalised.
  // Returning 1 here would dock every short honest set.
  const tempo = tempoFromReps(cycles(new Array(MIN_REPS_FOR_FATIGUE - 1).fill(2000)));
  strictEqual(tempo.fatigueSlope, null);
  strictEqual(tempo.fatiguePenalty, 0);
});

test("tempoFactor · a long set with no slowdown pays the fatigue penalty", () => {
  const n = MIN_REPS_FOR_FATIGUE;
  const flat = tempoFromReps(cycles(new Array(n).fill(2000)));
  near(flat.fatigueSlope ?? 0, 1, 1e-12);
  ok(
    flat.fatigueSlope !== null && flat.fatigueSlope < FATIGUE_SLOPE_HEALTHY,
    "should be below healthy",
  );
  // slope 1.0 against a healthy 1.02, over a 0.02-wide band → saturated.
  near(flat.fatiguePenalty, 0.15, 1e-12);
  // Both terms fire on a long metronome: 1 − 0.35 − 0.15 = 0.50, exactly the floor.
  near(flat.tempoFactor, TEMPO_FLOOR, 1e-12);
});

test("tempoFactor · a slowing set pays no fatigue penalty", () => {
  // 2000 rising to 2900 in ten steps: the last third is well over 1.02x the first.
  const lengths = Array.from({ length: 12 }, (_, i) => 2000 + 90 * i);
  const tempo = tempoFromReps(cycles(lengths));
  ok(
    (tempo.fatigueSlope ?? 0) > FATIGUE_SLOPE_HEALTHY,
    `slope ${tempo.fatigueSlope} should be healthy`,
  );
  strictEqual(tempo.fatiguePenalty, 0);
});

test("tempoFactor · an impossible median cycle forces the 0.5 floor regardless of the rest", () => {
  // Deliberately well-spread and heavily drifted — both other terms are clean —
  // so the only thing that can produce 0.5 here is the cadence floor.
  const lengths = Array.from({ length: 12 }, (_, i) => IMPOSSIBLE_CYCLE_MS - 300 + 20 * i);
  const tempo = tempoFromReps(cycles(lengths, 500));
  strictEqual(tempo.impossibleCadence, true);
  ok((tempo.medianCycleMs ?? 0) < IMPOSSIBLE_CYCLE_MS, "median must be under the floor");
  strictEqual(tempo.tempoFactor, TEMPO_FLOOR);
});

test("tempoFactor · the median, not the mean, decides impossibility", () => {
  // One absurdly long rep cannot rescue a set of 500 ms ones, and one very short
  // rep cannot condemn an honest set. Ten at 2000 and one at 100: median 2000.
  const tempo = tempoFromReps(cycles([...new Array(10).fill(2000), 100]));
  strictEqual(tempo.medianCycleMs, 2000);
  strictEqual(tempo.impossibleCadence, false);
});

test("tempoFactor · an empty set is neutral, not penalised", () => {
  // Holds take this path: `scoreHoldSet` calls `tempoFromReps([])` because the
  // contract's hold formula has no tempoFactor at all.
  const tempo = tempoFromReps([]);
  strictEqual(tempo.repCount, 0);
  strictEqual(tempo.medianCycleMs, null);
  strictEqual(tempo.meanCycleMs, null);
  strictEqual(tempo.cycleCv, null);
  strictEqual(tempo.fatigueSlope, null);
  strictEqual(tempo.minGapMs, null);
  strictEqual(tempo.subFloorGaps, 0);
  strictEqual(tempo.tempoFactor, 1);
});

test("tempoFactor · I6 gaps are counted but never priced", () => {
  // `subFloorGaps` feeds the CADENCE_FLOOR flag; it must not touch tempoFactor,
  // or I6 would become a scoring penalty by a route nobody decided on.
  const clean = tempoFromReps(
    cycles([2000, 2100, 1950, 2050, 2000, 2100], CADENCE_GAP_FLOOR_MS + 100),
  );
  const subFloor = tempoFromReps(
    cycles([2000, 2100, 1950, 2050, 2000, 2100], CADENCE_GAP_FLOOR_MS - 100),
  );
  strictEqual(clean.subFloorGaps, 0);
  strictEqual(subFloor.subFloorGaps, 5);
  strictEqual(subFloor.minGapMs, CADENCE_GAP_FLOOR_MS - 100);
  strictEqual(clean.tempoFactor, subFloor.tempoFactor);
});

// ---------------------------------------------------------------------------
// Holds — docs/api-contract.md:129-133, docs/requirements.md:170-175
// ---------------------------------------------------------------------------

/** plank's in-form band: 160–185, centre 172.5, half-width 12.5. */
const PLANK_BAND: HoldBand = { low: 160, high: 185, centre: 172.5, halfWidth: 12.5 };

function segment(tStartMs: number, tEndMs: number, meanSignal = 172.5, confMean = 0.9) {
  return { tStartMs, tEndMs, meanSignal, confMean };
}

test("scoreHold · api-contract.md:133 — 3 × 20 s is NOT worth 1 × 60 s", () => {
  // This is the open decision the contract flags for B, settled with a number.
  const single = scoreHold([segment(0, 60000)], PLANK_BAND);
  const triple = scoreHold(
    [segment(0, 20000), segment(21000, 41000), segment(42000, 62000)],
    PLANK_BAND,
  );

  strictEqual(single.qualifyingSegments, 1);
  strictEqual(single.discount, 1);
  near(single.repEquivalents, 60 / HOLD_SECONDS_PER_REP, 1e-12);
  strictEqual(single.repEquivalents, 20);

  strictEqual(triple.qualifyingSegments, 3);
  near(triple.discount, 1 / (1 + HOLD_SEGMENT_DISCOUNT * 2), 1e-12);
  ok(
    triple.repEquivalents < single.repEquivalents,
    "micro-breaks must not be free, or the movement is gameable",
  );
  // 20 × (1/1.2) = 16.667 — a 16.7% haircut for two extra breaks.
  near(triple.repEquivalents, 20 / 1.2, 1e-9);
});

test("scoreHold · api-contract.md:133 — only segments ≥ 5 s count at all", () => {
  const result = scoreHold([segment(0, 25000), segment(26000, 28000)], PLANK_BAND);
  strictEqual(MIN_HOLD_SEGMENT_MS, 5000);
  strictEqual(result.segmentsTotal, 2);
  strictEqual(result.qualifyingSegments, 1, "the 2 s micro-segment is a break, not a hold");
  strictEqual(result.qualifyingMs, 25000);
  // One qualifying segment means no discount — the multiplier counts qualifying
  // segments, so dropping below the floor must not also cost a haircut.
  strictEqual(result.discount, 1);
});

test("scoreHold · a segment of exactly MIN_HOLD_SEGMENT_MS qualifies", () => {
  const result = scoreHold([segment(0, MIN_HOLD_SEGMENT_MS)], PLANK_BAND);
  strictEqual(result.qualifyingSegments, 1);
  strictEqual(result.qualifyingMs, MIN_HOLD_SEGMENT_MS);
});

test("scoreHold · nothing qualifying is zero rep-equivalents at the form floor", () => {
  const result = scoreHold([segment(0, 1000), segment(2000, 3000)], PLANK_BAND);
  strictEqual(result.segmentsTotal, 2);
  strictEqual(result.qualifyingSegments, 0);
  strictEqual(result.qualifyingMs, 0);
  strictEqual(result.repEquivalents, 0);
  // The floor, not NaN or 0: `formFactor` still reaches the ledger row and a
  // zero-rep set must not divide by anything downstream.
  strictEqual(result.formFactor, FORM_FLOOR);
  // And an empty segment list behaves identically.
  strictEqual(scoreHold([], PLANK_BAND).repEquivalents, 0);
});

test("scoreHold · bandScore grades how central the hold sat, like romScore for reps", () => {
  const dead_centre = scoreHold([segment(0, 20000, 172.5)], PLANK_BAND);
  const halfway = scoreHold([segment(0, 20000, 178.75)], PLANK_BAND);
  const edge = scoreHold([segment(0, 20000, 185)], PLANK_BAND);
  const outside = scoreHold([segment(0, 20000, 195)], PLANK_BAND);

  near(dead_centre.bandScore, 1, 1e-12);
  // 1 − |178.75 − 172.5| / 12.5 = 1 − 0.5 = 0.5
  near(halfway.bandScore, 0.5, 1e-12);
  near(edge.bandScore, 0, 1e-12);
  strictEqual(outside.bandScore, 0, "clamped, never negative");
  // Symmetric on the low side: 160 is the other edge.
  near(scoreHold([segment(0, 20000, 160)], PLANK_BAND).bandScore, 0, 1e-12);
});

test("scoreHold · bandScore is averaged over qualifying segments only", () => {
  // A perfect 20 s hold plus a 4 s sag well outside the band. The sag is
  // dropped before the average, so it cannot drag the grade down — it was
  // already excluded from the seconds, and counting it twice would double-punish.
  const result = scoreHold([segment(0, 20000, 172.5), segment(21000, 25000, 195)], PLANK_BAND);
  strictEqual(result.qualifyingSegments, 1);
  near(result.bandScore, 1, 1e-12);
});

test("scoreHold · formFactor uses the same 0.60/0.40 shape as reps", () => {
  // bandScore 1, confScore 1 (confMean 0.9 ≥ 0.70) → 1.0.
  near(scoreHold([segment(0, 20000, 172.5, 0.9)], PLANK_BAND).formFactor, 1, 1e-12);
  // bandScore 0.5, confMean 0.35 → confScore 0.5: 0.60 + 0.40 × (0.30 + 0.20) = 0.80.
  near(scoreHold([segment(0, 20000, 178.75, 0.35)], PLANK_BAND).formFactor, 0.8, 1e-12);
});

test("scoreHold · a zero-width band cannot divide by zero", () => {
  // Guarded in `scoreHold`; a degenerate band is a seeding bug, and bandScore 1
  // is the reading that does not silently zero every hold of that movement.
  const result = scoreHold([segment(0, 20000, 90)], {
    low: 90,
    high: 90,
    centre: 90,
    halfWidth: 0,
  });
  strictEqual(result.bandScore, 1);
});

// ---------------------------------------------------------------------------
// Caps — docs/requirements.md:177-180
// ---------------------------------------------------------------------------

test("capSet · requirements.md:178 — one 500-rep set cannot own the city", () => {
  strictEqual(capSet(PER_SET_CAP), PER_SET_CAP);
  strictEqual(capSet(PER_SET_CAP - 1), PER_SET_CAP - 1);
  strictEqual(capSet(10000), PER_SET_CAP);
  strictEqual(capSet(0), 0);
});

test("applyDailyCap · caps.ts:42-44 — the three documented cases", () => {
  near(applyDailyCap(1000, 0), DAY_FULL_UNTIL + 400 * DAY_HALF_RATE, 1e-9);
  strictEqual(applyDailyCap(1000, 0), 800);
  strictEqual(applyDailyCap(100, 700), 50);
  strictEqual(applyDailyCap(100, 1300), 25);
});

test("applyDailyCap · requirements.md:179 — full rate up to DAY_FULL_UNTIL", () => {
  strictEqual(applyDailyCap(100, 0), 100);
  strictEqual(applyDailyCap(DAY_FULL_UNTIL, 0), DAY_FULL_UNTIL);
  strictEqual(dailyCapApplied(100, 0), false);
});

test("applyDailyCap · marginal, not a flat re-rating of the whole day", () => {
  // A session that straddles the boundary is split. If this were a flat
  // multiplier on the day's total, crossing 600 would retroactively halve
  // everything earned before it — and the ledger would disagree with the
  // responses already sent.
  const straddle = applyDailyCap(100, 550);
  near(straddle, 50 + 50 * DAY_HALF_RATE, 1e-9);
  strictEqual(straddle, 75);
  // The same 100 raw points are worth less the more is already banked.
  ok(applyDailyCap(100, 0) > applyDailyCap(100, 700), "half band must pay less than full");
  ok(applyDailyCap(100, 700) > applyDailyCap(100, 1300), "tail band must pay less than half");
});

test("applyDailyCap · a session spanning all three bands splits correctly", () => {
  // already 500, raw 900 → 100 at full, 600 at half, 200 at tail.
  const expected = 100 + 600 * DAY_HALF_RATE + 200 * DAY_TAIL_RATE;
  near(applyDailyCap(900, 500), expected, 1e-9);
  strictEqual(applyDailyCap(900, 500), 450);
});

test("applyDailyCap · degenerate inputs cannot produce a negative or NaN award", () => {
  strictEqual(applyDailyCap(0, 0), 0);
  strictEqual(applyDailyCap(-50, 0), 0);
  strictEqual(dailyCapApplied(0, 0), false);
  strictEqual(dailyCapApplied(-50, 0), false);
  // A negative `alreadyEarned` (a voided session over-correcting a counter)
  // clamps to zero rather than granting extra full-rate room.
  strictEqual(applyDailyCap(100, -1000), 100);
  // Far past the tail: everything is at the tail rate, never below zero.
  near(applyDailyCap(100, 1e9), 100 * DAY_TAIL_RATE, 1e-9);
});

test("dailyCapApplied · true exactly when the award is less than the raw total", () => {
  strictEqual(dailyCapApplied(100, 0), false);
  strictEqual(dailyCapApplied(DAY_FULL_UNTIL, 0), false);
  strictEqual(dailyCapApplied(DAY_FULL_UNTIL + 1, 0), true);
  strictEqual(dailyCapApplied(100, DAY_HALF_UNTIL), true);
});

// ---------------------------------------------------------------------------
// RepScore — docs/requirements.md:158
// ---------------------------------------------------------------------------

function repSet(reps: EvidenceRep[], movementId = "squat", restSignal = 175): EvidenceSet {
  return {
    movementId,
    measurementType: "repBodyweight",
    startedAtMs: reps[0].tStartMs - 500,
    endedAtMs: reps[reps.length - 1].tEndMs + 500,
    capture: { fpsMean: 30, framesTotal: 300, framesDropped: 0, modelVariant: "base" },
    calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal },
    reps,
    holdSegments: [],
  };
}

function evidenceOf(sets: EvidenceSet[]): Evidence {
  return {
    sessionId: "00000000-0000-4000-8000-000000000001",
    movementConfigVersion: CONFIG_VERSION,
    location: { lat: 51.5074, lng: -0.1278, accuracyM: 8, isMocked: false },
    spotId: null,
    sets,
  };
}

const ALL_UNLOCKED = new Set(testCatalogue().movements.keys());

test("RepScore · requirements.md:158 — reps × difficulty × formFactor × tempoFactor", () => {
  // Ten perfect squats: romScore 1 (peakExtreme 80 = romTarget), confScore 1,
  // and enough spread and drift that neither tempo term fires.
  const lengths = Array.from({ length: 10 }, (_, i) => 2000 + 120 * i + 90 * (i % 3));
  const set = repSet(cycles(lengths).map((r) => ({ ...r, peakExtreme: 80 })));
  const { scored, flags } = scoreSet(set, 0, {
    catalogue: testCatalogue(),
    unlockedMovements: ALL_UNLOCKED,
    alreadyEarnedToday: 0,
  });

  strictEqual(scored.formFactor, 1);
  strictEqual(scored.tempoFactor, 1);
  strictEqual(scored.difficulty, 1.0);
  // 10 × 1.0 × 1.0 × 1.0 = 10. The formula must be reproducible on a calculator
  // from the golden's four factors — that is why all four are persisted.
  strictEqual(scored.repScore, 10);
  strictEqual(scored.cappedScore, 10);
  strictEqual(scored.scored, true);
  strictEqual(flags.length, 0);
});

test("RepScore · difficulty comes from the catalogue, never from the payload", () => {
  // pull_up is 1.8; pistol_squat is 2.4. Same rep shape, different multiplier.
  const lengths = Array.from({ length: 10 }, (_, i) => 2400 + 120 * i + 90 * (i % 3));
  const score = (movementId: string, peak: number, rest: number) =>
    scoreSet(
      repSet(cycles(lengths).map((r) => ({ ...r, peakExtreme: peak })), movementId, rest),
      0,
      {
        catalogue: testCatalogue(),
        unlockedMovements: ALL_UNLOCKED,
        alreadyEarnedToday: 0,
      },
    ).scored;

  // pull_up: enterPeak 90, romTarget 55 → peakExtreme 55 gives romScore 1.
  const pullUp = score("pull_up", 55, 175);
  strictEqual(pullUp.difficulty, 1.8);
  strictEqual(pullUp.formFactor, 1);
  near(pullUp.repScore, 10 * 1.8, 1e-9);

  // pistol_squat shares the squat's offsets, so peakExtreme 80 again gives 1.
  const pistol = score("pistol_squat", 80, 175);
  strictEqual(pistol.difficulty, 2.4);
  near(pistol.repScore, 10 * 2.4, 1e-9);
});

test("RepScore · holds use requirements.md:170 — (seconds / 3) × difficulty × formFactor", () => {
  const set: EvidenceSet = {
    movementId: "plank",
    measurementType: "holdTime",
    startedAtMs: 0,
    endedAtMs: 61000,
    capture: { fpsMean: 30, framesTotal: 1830, framesDropped: 0, modelVariant: "base" },
    calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: 178 },
    reps: [],
    holdSegments: [segment(500, 60500, 172.5, 0.9)],
  };
  const { scored } = scoreSet(set, 0, {
    catalogue: testCatalogue(),
    unlockedMovements: ALL_UNLOCKED,
    alreadyEarnedToday: 0,
  });

  strictEqual(scored.holdMs, 60000);
  strictEqual(scored.formFactor, 1);
  strictEqual(scored.difficulty, 1.0);
  // 20 rep-equivalents × 1.0 × 1.0 = 20 — requirements.md:173's "a 60-second
  // plank is worth ~20 rep-equivalents before difficulty".
  strictEqual(scored.repScore, 20);
  // No tempoFactor on a hold: there is no cadence to be robotic about.
  strictEqual(scored.tempoFactor, 1);
  strictEqual(scored.repCount, 0);
});

test("I10 · a locked movement scores ZERO but still reports what was forgone", () => {
  // Scoring nothing satisfies I10 without the hard lockout I13 warns against.
  const lengths = Array.from({ length: 10 }, (_, i) => 3200 + 120 * i + 90 * (i % 3));
  const set = repSet(cycles(lengths).map((r) => ({ ...r, peakExtreme: 80 })), "pistol_squat");
  const { scored, flags } = scoreSet(set, 0, {
    catalogue: testCatalogue(),
    unlockedMovements: new Set(["squat"]),
    alreadyEarnedToday: 0,
  });

  strictEqual(scored.unlocked, false);
  strictEqual(scored.cappedScore, 0);
  strictEqual(scored.scored, false);
  // The raw score is still computed, so MOVEMENT_NOT_UNLOCKED can say what the
  // athlete would have earned. Zero here would make the flag useless.
  ok(scored.repScore > 0, "repScore must be computed even for a locked movement");
  strictEqual(flags.length, 1);
  strictEqual(flags[0].code, MOVEMENT_NOT_UNLOCKED);
  strictEqual(flags[0].severity, "warn");
  strictEqual(flags[0].setIndex, 0);
});

test("I11 · SET_CAPPED is info-severity and reports both sides of the cap", () => {
  // 200 perfect squats at difficulty 1.0 → raw 200, capped at 150.
  const lengths = Array.from({ length: 200 }, (_, i) => 2000 + 40 * i + 90 * (i % 3));
  const set = repSet(cycles(lengths).map((r) => ({ ...r, peakExtreme: 80 })));
  const { scored, flags } = scoreSet(set, 0, {
    catalogue: testCatalogue(),
    unlockedMovements: ALL_UNLOCKED,
    alreadyEarnedToday: 0,
  });

  strictEqual(scored.repScore, 200);
  strictEqual(scored.cappedScore, PER_SET_CAP);
  const capped = flags.filter((f) => f.code === SET_CAPPED);
  strictEqual(capped.length, 1);
  strictEqual(capped[0].severity, "info");
  strictEqual(capped[0].detail?.raw, 200);
  strictEqual(capped[0].detail?.capped, PER_SET_CAP);
  // A set exactly at the cap is not "capped" and must not be flagged.
  const exact = scoreSet(
    repSet(cycles(lengths.slice(0, 150)).map((r) => ({ ...r, peakExtreme: 80 }))),
    0,
    {
      catalogue: testCatalogue(),
      unlockedMovements: ALL_UNLOCKED,
      alreadyEarnedToday: 0,
    },
  );
  strictEqual(exact.scored.repScore, 150);
  strictEqual(exact.flags.filter((f) => f.code === SET_CAPPED).length, 0);
});

test("xp · requirements.md:183 — RepScore × streakMultiplier, multiplier 1.0 in this slice", () => {
  const lengths = Array.from({ length: 10 }, (_, i) => 2000 + 120 * i + 90 * (i % 3));
  const score = scoreEvidence(
    evidenceOf([repSet(cycles(lengths).map((r) => ({ ...r, peakExtreme: 80 })))]),
    {
      catalogue: testCatalogue(),
      unlockedMovements: ALL_UNLOCKED,
      alreadyEarnedToday: 0,
    },
  );
  strictEqual(score.rawTotal, 10);
  strictEqual(score.awardedTotal, 10);
  strictEqual(score.xp, 10);
  strictEqual(score.flags.length, 0);
});

test("awardedTotal · the daily cap applies to the sum of capped sets, not per set", () => {
  const lengths = Array.from({ length: 10 }, (_, i) => 2000 + 120 * i + 90 * (i % 3));
  const perfect = () => repSet(cycles(lengths).map((r) => ({ ...r, peakExtreme: 80 })));
  const score = scoreEvidence(evidenceOf([perfect(), perfect(), perfect()]), {
    catalogue: testCatalogue(),
    unlockedMovements: ALL_UNLOCKED,
    alreadyEarnedToday: DAY_FULL_UNTIL - 10,
  });
  // 3 × 10 = 30 raw; only 10 of that is still at full rate, the rest is halved.
  strictEqual(score.rawTotal, 30);
  near(score.awardedTotal, 10 + 20 * DAY_HALF_RATE, 1e-9);
  strictEqual(score.awardedTotal, 20);
  strictEqual(score.xp, 20);
});
