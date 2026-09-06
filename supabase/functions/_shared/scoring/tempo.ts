/// tempoFactor — the [0.5, 1.0] term that penalises robotic or impossible
/// cadence (requirements.md §4, I6, I9).
///
/// The premise is worth stating plainly: bots are metronomes, humans are not. A
/// human set has spread in its cycle times and slows down as it fatigues. Both
/// absences are cheap to measure and hard to fake at the same time — injecting
/// random jitter fixes the variance check but not the drift, and adding drift
/// fixes the drift but not the variance.
///
/// Every constant here is a scoring constant, not a validator threshold, because
/// tempoFactor multiplies directly into RepScore. They are B's to sanity-check
/// against a real set on Day 4 (roles.md §5).

import type { EvidenceRep } from "../evidence/schema.ts";
import { clamp } from "./rom.ts";

/** Below this median cycle the set is not humanly possible. */
export const IMPOSSIBLE_CYCLE_MS = 900;

/** I6 — reject inter-rep gaps under 0.4 s. Flagged, never a tempo term. */
export const CADENCE_GAP_FLOOR_MS = 400;

export const TEMPO_FLOOR = 0.5;
export const TEMPO_CEILING = 1.0;

/** Spread needs a handful of reps before a low cv means anything. */
export const MIN_REPS_FOR_VARIANCE = 5;
/** Drift needs enough of a set to have a beginning and an end. */
export const MIN_REPS_FOR_FATIGUE = 10;

/** Coefficient of variation at or above which uniformity costs nothing. */
export const CV_HEALTHY = 0.06;
export const UNIFORMITY_MAX_PENALTY = 0.35;

/** Last-third / first-third cycle ratio at or above which drift costs nothing.
 * Humans slow down, so a healthy slope is slightly ABOVE 1. */
export const FATIGUE_SLOPE_HEALTHY = 1.02;
export const FATIGUE_MAX_PENALTY = 0.15;

export interface TempoStats {
  repCount: number;
  /** tEndMs - tStartMs per rep. */
  cyclesMs: number[];
  medianCycleMs: number | null;
  meanCycleMs: number | null;
  /** Population stddev / mean of the cycles; null when too few reps. */
  cycleCv: number | null;
  /** mean(last third) / mean(first third); null when too few reps. */
  fatigueSlope: number | null;
  /** Smallest inter-rep gap; null for a single-rep set. */
  minGapMs: number | null;
  /** Count of gaps below the I6 floor. */
  subFloorGaps: number;
  uniformityPenalty: number;
  fatiguePenalty: number;
  impossibleCadence: boolean;
  tempoFactor: number;
}

export function mean(values: number[]): number | null {
  if (values.length === 0) return null;
  let total = 0;
  for (const v of values) total += v;
  return total / values.length;
}

export function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 === 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid];
}

/** Population standard deviation — the whole set is the population here. */
export function stddev(values: number[]): number {
  const m = mean(values);
  if (m === null) return 0;
  let acc = 0;
  for (const v of values) acc += (v - m) * (v - m);
  return Math.sqrt(acc / values.length);
}

/**
 * Derives every tempo statistic and the resulting tempoFactor from a set's reps.
 *
 * An empty or single-rep set has nothing to say about cadence: `tempoFactor` is
 * 1.0 and the variance/drift terms are null rather than penalised, because
 * absence of evidence is not evidence of a bot.
 */
export function tempoFromReps(reps: EvidenceRep[]): TempoStats {
  const cyclesMs = reps.map((r) => r.tEndMs - r.tStartMs);

  const gaps: number[] = [];
  for (let i = 1; i < reps.length; i++) {
    gaps.push(reps[i].tStartMs - reps[i - 1].tEndMs);
  }
  const subFloorGaps = gaps.filter((g) => g < CADENCE_GAP_FLOOR_MS).length;

  const medianCycleMs = median(cyclesMs);
  const meanCycleMs = mean(cyclesMs);

  const impossibleCadence = medianCycleMs !== null && medianCycleMs < IMPOSSIBLE_CYCLE_MS;

  let cycleCv: number | null = null;
  let uniformityPenalty = 0;
  if (cyclesMs.length >= MIN_REPS_FOR_VARIANCE && meanCycleMs !== null && meanCycleMs > 0) {
    cycleCv = stddev(cyclesMs) / meanCycleMs;
    uniformityPenalty = clamp((CV_HEALTHY - cycleCv) / CV_HEALTHY, 0, 1) * UNIFORMITY_MAX_PENALTY;
  }

  let fatigueSlope: number | null = null;
  let fatiguePenalty = 0;
  if (cyclesMs.length >= MIN_REPS_FOR_FATIGUE) {
    const k = Math.floor(cyclesMs.length / 3);
    const firstMean = mean(cyclesMs.slice(0, k));
    const lastMean = mean(cyclesMs.slice(cyclesMs.length - k));
    if (firstMean !== null && lastMean !== null && firstMean > 0) {
      fatigueSlope = lastMean / firstMean;
      fatiguePenalty =
        clamp((FATIGUE_SLOPE_HEALTHY - fatigueSlope) / (FATIGUE_SLOPE_HEALTHY - 1), 0, 1) *
        FATIGUE_MAX_PENALTY;
    }
  }

  const tempoFactor = impossibleCadence ? TEMPO_FLOOR : clamp(
    TEMPO_CEILING - uniformityPenalty - fatiguePenalty,
    TEMPO_FLOOR,
    TEMPO_CEILING,
  );

  return {
    repCount: reps.length,
    cyclesMs,
    medianCycleMs,
    meanCycleMs,
    cycleCv,
    fatigueSlope,
    minGapMs: gaps.length === 0 ? null : Math.min(...gaps),
    subFloorGaps,
    uniformityPenalty,
    fatiguePenalty,
    impossibleCadence,
    tempoFactor,
  };
}
