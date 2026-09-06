/// Builds the jsonb payloads that `record_session_outcome()` (migration 0005)
/// consumes.
///
/// This file is the TypeScript half of a contract whose other half is plpgsql,
/// and the two are separated by a `::double precision` cast that will happily
/// throw at 2 a.m. on demo night over a renamed key. It is pure — no client, no
/// clock — so the key names can be asserted in a test instead of discovered in a
/// server log. `test/server/outcome_payload_test.ts` pins them.
///
/// Field order below mirrors the INSERT column order in 0005 deliberately: reading
/// the two side by side is how you spot a mismatch.

import type { Evidence, EvidenceRep, EvidenceSet } from "./evidence/schema.ts";
import type { Flag } from "./flags.ts";
import type { EvidenceScore, ScoredSet } from "./scoring/score.ts";

export interface RepPayload {
  i: number;
  t_start_ms: number;
  t_end_ms: number;
  rest_extreme: number;
  peak_extreme: number;
  conf_mean: number;
  conf_min: number;
  concentric_ms?: number;
  eccentric_ms?: number;
  hip_drift_norm?: number;
  shoulder_wrist_dy_norm?: number;
  rom_score: number;
}

export interface TracePayload {
  hz: number;
  t0_ms: number;
  primary: number[];
  conf_mean: number[];
}

export interface SetPayload {
  movement_id: string;
  measurement_type: string;
  rep_count: number;
  hold_ms: number;
  form_factor: number;
  tempo_factor: number;
  rep_score: number;
  capped_score: number;
  scored: boolean;
  capture: unknown;
  calibration: unknown;
  reps: RepPayload[];
  trace: TracePayload | null;
}

export interface FlagPayload {
  code: string;
  severity: string;
  set_index: number | null;
  rep_index: number | null;
  detail: Record<string, unknown>;
}

/**
 * Zips one Evidence set with its scored twin.
 *
 * `scoreSet` maps `set.reps` positionally, so `scored.reps[j]` is the grade for
 * `evidence.reps[j]`. The length assertion is not paranoia — it is the check that
 * turns a future refactor of that mapping into a test failure here rather than a
 * silently mis-aligned `rom_score` column in production.
 */
function repPayloads(set: EvidenceSet, scored: ScoredSet): RepPayload[] {
  if (set.reps.length !== scored.reps.length) {
    throw new Error(
      `rep count mismatch while building the outcome payload: evidence has ` +
        `${set.reps.length}, scoring produced ${scored.reps.length}`,
    );
  }
  return set.reps.map((r: EvidenceRep, j: number) => ({
    i: r.i,
    t_start_ms: r.tStartMs,
    t_end_ms: r.tEndMs,
    rest_extreme: r.restExtreme,
    peak_extreme: r.peakExtreme,
    conf_mean: r.confMean,
    conf_min: r.confMin,
    concentric_ms: r.concentricMs,
    eccentric_ms: r.eccentricMs,
    hip_drift_norm: r.hipDriftNorm,
    shoulder_wrist_dy_norm: r.shoulderWristDyNorm,
    rom_score: scored.reps[j].romScore,
  }));
}

function tracePayload(set: EvidenceSet): TracePayload | null {
  const trace = set.trace;
  if (trace === undefined) return null;
  return {
    hz: trace.hz,
    t0_ms: trace.t0Ms,
    primary: trace.primary,
    conf_mean: trace.confMean,
  };
}

export function toSetPayloads(evidence: Evidence, score: EvidenceScore): SetPayload[] {
  if (evidence.sets.length !== score.sets.length) {
    throw new Error(
      `set count mismatch while building the outcome payload: evidence has ` +
        `${evidence.sets.length}, scoring produced ${score.sets.length}`,
    );
  }
  return evidence.sets.map((set, i) => {
    const scored = score.sets[i];
    if (scored.setIndex !== i) {
      throw new Error(`scored set at position ${i} reports setIndex ${scored.setIndex}`);
    }
    return {
      movement_id: set.movementId,
      measurement_type: set.measurementType,
      rep_count: scored.repCount,
      hold_ms: Math.round(scored.holdMs),
      form_factor: scored.formFactor,
      tempo_factor: scored.tempoFactor,
      rep_score: scored.repScore,
      capped_score: scored.cappedScore,
      scored: scored.scored,
      // Stored verbatim. These are the only place the raw observation quality
      // survives, and they feed no score term — they exist so A can retune
      // against what the camera actually saw.
      capture: set.capture,
      calibration: set.calibration,
      reps: repPayloads(set, scored),
      trace: tracePayload(set),
    };
  });
}

export function toFlagPayloads(flags: readonly Flag[]): FlagPayload[] {
  return flags.map((f) => ({
    code: f.code,
    severity: f.severity,
    set_index: f.setIndex ?? null,
    rep_index: f.repIndex ?? null,
    detail: f.detail ?? {},
  }));
}
