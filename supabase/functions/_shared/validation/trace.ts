/// Trace / summary cross-check (B-25, I8) — the verification that earns its keep.
///
/// Levels 1 and 2 of docs/api-contract.md §"What the server can actually verify":
/// recomputing the score from client-supplied measurements satisfies I1, but it
/// is still recomputation from numbers the client chose. This check makes a
/// forger fake TWO representations coherently — the per-rep summary and the
/// independent 5 Hz time series — which is a materially different problem from
/// faking twenty numbers.
///
/// Three assertions per rep window, and one across the whole set:
///
///   1. `peakExtreme` must be AT LEAST AS EXTREME as the trace extreme. 5 Hz
///      sampling can only miss the true peak, never overshoot it, so a claimed
///      peak shallower than what the trace shows is physically impossible.
///   2. …and within tolerance of it (15 degrees, or 0.15 for ratio signals). A
///      rep claiming a 52 degree peak when the trace bottoms out at 110 is a
///      contradiction even though it satisfies (1).
///   3. Threshold crossings counted directly in `trace.primary` must be within
///      TRACE_REP_TOLERANCE of `reps.length`.
///
/// All three are SHADOW flags (I13). None of them rejects at the gate and none of
/// them changes the score — a contradiction found on demo day must never lock a
/// judge out mid-take. They accumulate in `session_flags`, and a human voids the
/// session afterwards with `void_session()` if the pattern holds up.

import type { EvidenceSet } from "../evidence/schema.ts";
import type { ResolvedThresholds } from "../evidence/thresholds.ts";
import { atLeastAsExtreme, moreExtreme } from "../evidence/thresholds.ts";
import {
  type Flag,
  flag,
  TRACE_INSUFFICIENT,
  TRACE_MISSING,
  TRACE_PEAK_INCONSISTENT,
  TRACE_PEAK_OUT_OF_TOLERANCE,
  TRACE_REP_COUNT_DIVERGENT,
} from "../flags.ts";
import { countReps } from "./rep_machine.ts";

/** api-contract.md: "must be within ±1 of reps.length". */
export const TRACE_REP_TOLERANCE = 1;

/** Fewer samples than this inside a rep window and no assertion is safe. */
export const MIN_SAMPLES_PER_WINDOW = 2;

export interface TraceCheckResult {
  flags: Flag[];
  /** Reps counted from the trace alone; null when there was no trace to count. */
  traceReps: number | null;
  repsChecked: number;
  repsInsufficient: number;
}

const NO_TRACE: TraceCheckResult = {
  flags: [],
  traceReps: null,
  repsChecked: 0,
  repsInsufficient: 0,
};

/**
 * Reconstructs sample times from `hz` and `t0Ms`. The trace is stored as parallel
 * arrays roughly 10x smaller than an array of objects (I8), so time is implicit
 * and has to be rebuilt here.
 */
export function sampleTimes(trace: { hz: number; t0Ms: number; primary: number[] }): number[] {
  const step = 1000 / trace.hz;
  const times: number[] = new Array(trace.primary.length);
  for (let k = 0; k < trace.primary.length; k++) times[k] = trace.t0Ms + k * step;
  return times;
}

export function crossCheckTrace(
  set: EvidenceSet,
  setIndex: number,
  thresholds: ResolvedThresholds,
): TraceCheckResult {
  // Holds first, and BEFORE the missing-trace check below. A hold has no state
  // machine and no reps, so there is nothing for a trace to be cross-checked
  // against: the in-form band already gated accrual upstream, and the segment
  // timings are the summary. Assertions 1–3 are rep-shaped.
  //
  // Ordering matters. Flagging an absent trace on a holdTime set would put an
  // `info` flag on every honest plank, wall sit and dead hang forever — noise
  // that trains whoever reviews `session_flags` to skip `info`, which is where
  // SET_CAPPED and DAILY_CAP_APPLIED live.
  //
  // Keyed off `measurementType` rather than `direction` alone. The movement's
  // measurement type is the authoritative statement that there is no rep state
  // machine; `direction` is a property of a versioned offsets row, and a seeding
  // slip can put 'decreasing' on a holdTime movement — 0003's family backfill
  // did exactly that to `dead_hang`, a tier-1 movement in the `pull` family,
  // which would have run an honest dead hang through the crossing count against
  // an empty rep list and fabricated TRACE_REP_COUNT_DIVERGENT. Both are checked
  // so either one being wrong is not enough to break this.
  if (set.measurementType === "holdTime" || thresholds.direction === "hold") return NO_TRACE;

  const trace = set.trace;

  // Track A does not emit a contract-shaped trace yet — the two recorders that
  // exist in capture/pipeline/ are debug-only local landmark and diagnostics
  // dumps, explicitly never submitted. An absent trace must therefore score
  // normally: `info`, not a rejection, so this backend is deployable before
  // Seam 1 closes.
  if (trace === undefined) {
    return {
      ...NO_TRACE,
      flags: [{ ...flag(TRACE_MISSING, "info"), setIndex }],
    };
  }

  const flags: Flag[] = [];
  const times = sampleTimes(trace);
  const direction = thresholds.direction;

  // Reps are ordered and non-overlapping (enforced by parseEvidence), so one
  // forward cursor walks the whole set in O(samples + reps) instead of rescanning.
  let cursor = 0;
  let repsChecked = 0;
  let repsInsufficient = 0;

  for (const rep of set.reps) {
    while (cursor < times.length && times[cursor] < rep.tStartMs) cursor++;

    const from = cursor;
    let to = from;
    while (to < times.length && times[to] <= rep.tEndMs) to++;

    if (to - from < MIN_SAMPLES_PER_WINDOW) {
      repsInsufficient++;
      flags.push({
        ...flag(TRACE_INSUFFICIENT, "warn", {
          samplesInWindow: to - from,
          tStartMs: rep.tStartMs,
          tEndMs: rep.tEndMs,
        }),
        setIndex,
        repIndex: rep.i,
      });
      continue;
    }

    let traceExtreme = trace.primary[from];
    for (let k = from + 1; k < to; k++) {
      traceExtreme = moreExtreme(traceExtreme, trace.primary[k], direction);
    }

    const claimed = rep.peakExtreme;
    const delta = Math.abs(claimed - traceExtreme);

    if (!atLeastAsExtreme(claimed, traceExtreme, direction)) {
      // The client samples at ~15 fps and the trace at 5 Hz, so the client can
      // only ever see MORE of the movement. A shallower claimed peak than the
      // downsampled one is not a measurement error, it is a fabrication.
      flags.push({
        ...flag(TRACE_PEAK_INCONSISTENT, "contradiction", {
          claimed,
          traceExtreme,
          direction,
        }),
        setIndex,
        repIndex: rep.i,
      });
    } else if (delta > thresholds.tolerance) {
      flags.push({
        ...flag(TRACE_PEAK_OUT_OF_TOLERANCE, "contradiction", {
          claimed,
          traceExtreme,
          delta,
          tolerance: thresholds.tolerance,
        }),
        setIndex,
        repIndex: rep.i,
      });
    }

    repsChecked++;
  }

  const crossing = countReps(
    trace.primary,
    thresholds.enterPeak,
    thresholds.enterRest,
    direction,
  );
  const divergence = Math.abs(crossing.reps - set.reps.length);
  if (divergence > TRACE_REP_TOLERANCE) {
    flags.push({
      ...flag(TRACE_REP_COUNT_DIVERGENT, "contradiction", {
        traceReps: crossing.reps,
        claimedReps: set.reps.length,
        divergence,
        tolerance: TRACE_REP_TOLERANCE,
      }),
      setIndex,
    });
  }

  return { flags, traceReps: crossing.reps, repsChecked, repsInsufficient };
}
