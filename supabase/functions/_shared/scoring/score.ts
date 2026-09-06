/// The scoring engine — server-side recompute of every point (I1).
///
///     RepScore = reps × difficulty × formFactor × tempoFactor
///     holdTime:  RepScore = (seconds / 3) × discount × difficulty × formFactor
///
/// Nothing here reads a number the client computed. The inputs are measurements
/// (angles, confidences, timestamps) and the catalogue; the outputs are scores.
/// That asymmetry is the entire content of I1 and the reason `parseEvidence`
/// rejects a payload carrying a `score` field.

import type { Evidence, EvidenceSet, MeasurementType } from "../evidence/schema.ts";
import type { Catalogue, ResolvedThresholds } from "../evidence/thresholds.ts";
import { resolveThresholds } from "../evidence/thresholds.ts";
import {
  CADENCE_FLOOR,
  CLIENT_COUNT_DIVERGENT,
  DAILY_CAP_APPLIED,
  type Flag,
  flag,
  IMPOSSIBLE_CADENCE,
  KIP_DETECTED,
  MOVEMENT_NOT_UNLOCKED,
  NO_FATIGUE_DRIFT,
  PULLUP_UNCONFIRMED,
  SET_CAPPED,
  TEMPO_UNIFORM,
} from "../flags.ts";
import { repFormFactor, setFormFactor } from "./form.ts";
import { type HoldResult, scoreHold } from "./holds.ts";
import { applyDailyCap, capSet, dailyCapApplied, PER_SET_CAP } from "./caps.ts";
import { tempoFromReps, type TempoStats } from "./tempo.ts";

export interface ScoredRep {
  i: number;
  romScore: number;
  confScore: number;
  /** The grade before kip / confirmation penalties. */
  baseFormFactor: number;
  kipDock: number;
  unconfirmed: boolean;
  formFactor: number;
}

export interface ScoredSet {
  setIndex: number;
  movementId: string;
  measurementType: MeasurementType;
  tier: number;
  difficulty: number;
  /** False when the movement is not unlocked, so the set scores zero (I10). */
  unlocked: boolean;
  repCount: number;
  holdMs: number;
  formFactor: number;
  tempoFactor: number;
  /** Before any cap. */
  repScore: number;
  /** After the per-set cap and tier gating. This is what reaches the ledger. */
  cappedScore: number;
  scored: boolean;
  tempo: TempoStats;
  hold: HoldResult | null;
  reps: ScoredRep[];
  /** The resolved absolute thresholds — persisted alongside the set for replay. */
  thresholds: ResolvedThresholds;
}

export interface EvidenceScore {
  sets: ScoredSet[];
  /** Sum of per-set capped scores, before the daily marginal cap. */
  rawTotal: number;
  /** What is actually awarded and written to the ledger. */
  awardedTotal: number;
  /**
   * XP = RepScore × streakMultiplier. The multiplier is fixed at 1.0 in this
   * slice — there is no streak table yet (B-15 owns the curve). Streak applies
   * to XP only and never to territory power, so this is the one place it can
   * later be inserted without touching scoring.
   */
  xp: number;
  flags: Flag[];
}

export interface ScoreContext {
  catalogue: Catalogue;
  /** Movement ids this user has unlocked. T1/T2 are granted at signup. */
  unlockedMovements: ReadonlySet<string>;
  /** RepScore already banked today, from `daily_counters`. */
  alreadyEarnedToday: number;
}

function scoreRepSet(set: EvidenceSet, thresholds: ResolvedThresholds): {
  reps: ScoredRep[];
  formFactor: number;
  tempo: TempoStats;
  hold: null;
  repScore: number;
} {
  const reps: ScoredRep[] = set.reps.map((r) => {
    const form = repFormFactor(
      set.movementId,
      r.peakExtreme,
      thresholds.enterPeak,
      thresholds.romTarget,
      r.confMean,
      r.hipDriftNorm,
      r.shoulderWristDyNorm,
    );
    return {
      i: r.i,
      romScore: form.romScore,
      confScore: form.confScore,
      baseFormFactor: form.base,
      kipDock: form.kipDock,
      unconfirmed: form.unconfirmed,
      formFactor: form.formFactor,
    };
  });

  const formFactor = setFormFactor(reps.map((r) => r.formFactor));
  const tempo = tempoFromReps(set.reps);

  // reps.length is authoritative. clientRepCount exists for reconciliation only
  // and is never trusted as a count (api-contract.md:219).
  const repScore = reps.length * thresholds.movement.difficulty * formFactor * tempo.tempoFactor;

  return { reps, formFactor, tempo, hold: null, repScore };
}

function scoreHoldSet(set: EvidenceSet, thresholds: ResolvedThresholds): {
  reps: ScoredRep[];
  formFactor: number;
  tempo: TempoStats;
  hold: HoldResult;
  repScore: number;
} {
  // The schema guarantees a band for any holdTime movement; the fallback keeps
  // the function total rather than throwing on a seeding gap.
  const hold = scoreHold(
    set.holdSegments,
    thresholds.holdBand ?? { low: 0, high: 0, centre: 0, halfWidth: 0 },
  );
  // No tempo term for holds: there is no cadence to be robotic about, and the
  // contract's hold formula has no tempoFactor. A synthetic TempoStats keeps one
  // shape downstream instead of a nullable special case.
  const tempo = tempoFromReps([]);

  const repScore = hold.repEquivalents * thresholds.movement.difficulty * hold.formFactor;

  return { reps: [], formFactor: hold.formFactor, tempo, hold, repScore };
}

/** Scores one set. Throws `CatalogueError` if the movement or its offsets are unknown. */
export function scoreSet(
  set: EvidenceSet,
  setIndex: number,
  ctx: ScoreContext,
): { scored: ScoredSet; flags: Flag[] } {
  const thresholds = resolveThresholds(ctx.catalogue, set.movementId, set.calibration.restSignal);
  const unlocked = ctx.unlockedMovements.has(set.movementId);

  const result = set.measurementType === "holdTime"
    ? scoreHoldSet(set, thresholds)
    : scoreRepSet(set, thresholds);

  // Tier gating doubles as anti-cheat (I10): a user cannot score a movement they
  // have not unlocked, so nobody arrives claiming pistol squats with no history.
  // The set scores ZERO rather than the submission being rejected — scoring
  // nothing satisfies I10 without the hard lockout I13 warns against.
  const capped = unlocked ? capSet(result.repScore) : 0;

  const flags: Flag[] = [];
  const at = { setIndex };

  if (!unlocked) {
    flags.push({
      ...flag(MOVEMENT_NOT_UNLOCKED, "warn", {
        movementId: set.movementId,
        tier: thresholds.movement.tier,
        forgoneScore: round(result.repScore),
      }),
      ...at,
    });
  }
  if (unlocked && result.repScore > PER_SET_CAP + 1e-9) {
    flags.push({
      ...flag(SET_CAPPED, "info", { raw: round(result.repScore), capped: round(capped) }),
      ...at,
    });
  }

  // Tempo terms double as the I6/I9 plausibility signals — the same numbers that
  // price the set are the ones that describe whether it looked human, so they are
  // computed once here rather than again in a validator.
  if (result.tempo.impossibleCadence) {
    flags.push({
      ...flag(IMPOSSIBLE_CADENCE, "contradiction", {
        medianCycleMs: round(result.tempo.medianCycleMs ?? 0),
      }),
      ...at,
    });
  }
  if (result.tempo.uniformityPenalty > 0) {
    flags.push({
      ...flag(TEMPO_UNIFORM, "warn", {
        cycleCv: round(result.tempo.cycleCv ?? 0, 4),
        penalty: round(result.tempo.uniformityPenalty, 4),
      }),
      ...at,
    });
  }
  if (result.tempo.fatiguePenalty > 0) {
    flags.push({
      ...flag(NO_FATIGUE_DRIFT, "warn", {
        fatigueSlope: round(result.tempo.fatigueSlope ?? 0, 4),
        penalty: round(result.tempo.fatiguePenalty, 4),
      }),
      ...at,
    });
  }
  if (result.tempo.subFloorGaps > 0) {
    flags.push({
      ...flag(CADENCE_FLOOR, "warn", {
        subFloorGaps: result.tempo.subFloorGaps,
        minGapMs: result.tempo.minGapMs,
      }),
      ...at,
    });
  }

  for (const r of result.reps) {
    if (r.kipDock > 0) {
      flags.push({
        ...flag(KIP_DETECTED, "warn", { dock: round(r.kipDock, 4) }),
        setIndex,
        repIndex: r.i,
      });
    }
    if (r.unconfirmed) {
      flags.push({
        ...flag(PULLUP_UNCONFIRMED, "warn", {}),
        setIndex,
        repIndex: r.i,
      });
    }
  }

  if (set.clientRepCount !== undefined && set.clientRepCount !== set.reps.length) {
    flags.push({
      ...flag(CLIENT_COUNT_DIVERGENT, "warn", {
        clientRepCount: set.clientRepCount,
        repsSerialized: set.reps.length,
      }),
      ...at,
    });
  }

  return {
    scored: {
      setIndex,
      movementId: set.movementId,
      measurementType: set.measurementType,
      tier: thresholds.movement.tier,
      difficulty: thresholds.movement.difficulty,
      unlocked,
      repCount: result.reps.length,
      holdMs: result.hold ? result.hold.qualifyingMs : 0,
      formFactor: result.formFactor,
      tempoFactor: result.tempo.tempoFactor,
      repScore: result.repScore,
      cappedScore: capped,
      scored: unlocked && capped > 0,
      tempo: result.tempo,
      hold: result.hold,
      reps: result.reps,
      thresholds,
    },
    flags,
  };
}

/**
 * Scores a whole Evidence payload.
 *
 * Pure: no I/O, no clock, no randomness. Every input it needs is passed in
 * through [ScoreContext], which is what makes the golden-fixture suite possible
 * — the same function runs in a unit test, in the Edge Function, and in the
 * fixture generator, and must produce identical numbers in all three.
 */
export function scoreEvidence(evidence: Evidence, ctx: ScoreContext): EvidenceScore {
  const sets: ScoredSet[] = [];
  const flags: Flag[] = [];

  evidence.sets.forEach((set, i) => {
    const { scored, flags: setFlags } = scoreSet(set, i, ctx);
    sets.push(scored);
    flags.push(...setFlags);
  });

  const rawTotal = sets.reduce((acc, s) => acc + s.cappedScore, 0);
  const awardedTotal = applyDailyCap(rawTotal, ctx.alreadyEarnedToday);

  if (dailyCapApplied(rawTotal, ctx.alreadyEarnedToday)) {
    flags.push(
      flag(DAILY_CAP_APPLIED, "info", {
        alreadyEarnedToday: round(ctx.alreadyEarnedToday),
        rawTotal: round(rawTotal),
        awardedTotal: round(awardedTotal),
      }),
    );
  }

  return { sets, rawTotal, awardedTotal, xp: Math.round(awardedTotal), flags };
}

/** Round for persistence and for flag detail — never for intermediate maths. */
export function round(value: number, places = 6): number {
  const f = 10 ** places;
  return Math.round(value * f) / f;
}
