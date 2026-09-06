/// The 5 Hz trace synthesiser.
///
/// Track A owns the real emitter (`lib/features/capture/pipeline/`); this is the
/// test-side stand-in that produces a *contract-shaped* `EvidenceTrace` so the
/// cross-check in `_shared/validation/trace.ts` has something honest to agree
/// with and something dishonest to disagree with.
///
/// WHY A SYNTHESISER AND NOT NINE HAND-WRITTEN ARRAYS
/// A trace is 200 ms samples across a 40 s set — 200 numbers per fixture. Hand
/// writing them means the fixture's `reps[].peakExtreme` and its `trace.primary`
/// drift apart the first time anyone edits a threshold, and the failure mode is a
/// flag nobody meant to write. Generating the trace FROM the rep list makes the
/// two representations consistent by construction, which is the only way a
/// "expect zero flags" assertion means anything.
///
/// SHAPE
/// Each rep is one `sin^2` bump sitting on a flat baseline at `restSignal`:
///
///     value(t) = rest - (rest - depth) * sin^2( pi * (t - tStart) / (tEnd - tStart) )
///
/// `sin^2` rather than a triangle for two reasons. It is exactly `rest` at both
/// ends, so bumps and flat gaps join continuously with no seam for the crossing
/// counter to misread. And its apex is flat (quadratic, not linear), so 5 Hz
/// undersampling costs `A * pi^2 * (step / 2T)^2` degrees instead of
/// `A * step / T` — 2 degrees rather than 8 for a 2 s squat. That matters because
/// the tolerance is 15 degrees: a triangle wave would put fast honest reps
/// uncomfortably close to `TRACE_PEAK_OUT_OF_TOLERANCE`.
///
/// THE QUANTISATION INVARIANT
/// Samples are rounded to 2 dp TOWARD `restSignal`, never toward the apex. So the
/// synthesised trace is never more extreme than `depth`, and when `depth` equals a
/// rep's claimed `peakExtreme` the first trace assertion
/// (`atLeastAsExtreme(claimed, traceExtreme)`) holds with certainty rather than by
/// luck. Rounding to nearest would break it on a sample that lands exactly on the
/// apex.
///
/// Pure and deterministic: no clock, no `Math.random`, no I/O.

import type {
  EvidenceRep,
  EvidenceTrace,
} from "../../../supabase/functions/_shared/evidence/schema.ts";

/** One movement excursion in the signal, in absolute signal units. */
export interface Bump {
  tStartMs: number;
  tEndMs: number;
  /**
   * The value at the apex — an absolute signal reading, NOT an amplitude. For a
   * decreasing signal (squat) this is the bottom of the rep; for an increasing
   * one (jumping jack) the top.
   */
  depth: number;
}

export interface TraceSpec {
  /** Samples per second. The contract says ~5 Hz (I8). */
  hz: number;
  /** Time of sample zero, on the same offset clock as the reps. */
  t0Ms: number;
  /** Inclusive end of the sampled span — normally the set's `endedAtMs`. */
  tEndMs: number;
  /** The flat baseline between bumps; normally `calibration.restSignal`. */
  restSignal: number;
  /** Sorted, non-overlapping. */
  bumps: readonly Bump[];
  /** Per-sample confidence. The cross-check never reads it; stored for tuning. */
  confMean: number;
}

/** Rounds toward `rest`, i.e. away from the apex. See THE QUANTISATION INVARIANT. */
function quantise(value: number, rest: number, places = 2): number {
  const f = 10 ** places;
  return rest > value ? Math.ceil(value * f) / f : Math.floor(value * f) / f;
}

function bumpValue(bump: Bump, rest: number, t: number): number {
  const span = bump.tEndMs - bump.tStartMs;
  if (span <= 0) return rest;
  const phase = (t - bump.tStartMs) / span;
  const s = Math.sin(Math.PI * phase);
  return rest - (rest - bump.depth) * s * s;
}

/**
 * Builds a trace by walking sample times once and, for each, taking the bump that
 * contains it or the baseline. O(samples + bumps) — the bumps are sorted, so a
 * forward cursor suffices.
 */
export function makeTrace(spec: TraceSpec): EvidenceTrace {
  const stepMs = 1000 / spec.hz;
  const primary: number[] = [];
  const confMean: number[] = [];

  let cursor = 0;
  // `<= spec.tEndMs` so the final sample lands on the set boundary. The crossing
  // counter needs a reading at or above `enterRest` AFTER the last bump to emit
  // the final rep, and this is the sample that provides it.
  for (let t = spec.t0Ms; t <= spec.tEndMs + 1e-9; t += stepMs) {
    while (cursor < spec.bumps.length && spec.bumps[cursor].tEndMs < t) cursor++;

    const bump = cursor < spec.bumps.length && t >= spec.bumps[cursor].tStartMs
      ? spec.bumps[cursor]
      : undefined;

    const raw = bump === undefined ? spec.restSignal : bumpValue(bump, spec.restSignal, t);

    primary.push(quantise(raw, spec.restSignal));
    confMean.push(spec.confMean);
  }

  if (primary.length === 0) {
    throw new Error(
      `makeTrace produced no samples: t0Ms ${spec.t0Ms} is already past tEndMs ${spec.tEndMs}`,
    );
  }

  return { hz: spec.hz, t0Ms: spec.t0Ms, primary, confMean };
}

/** One bump per rep, apex at the rep's claimed extreme — the honest trace. */
export function bumpsFromReps(reps: readonly EvidenceRep[]): Bump[] {
  return reps.map((r) => ({ tStartMs: r.tStartMs, tEndMs: r.tEndMs, depth: r.peakExtreme }));
}

/**
 * Sanity check a generator should never trip, kept exported so the test suite can
 * assert it: every bump must fit inside the sampled span, or `makeTrace` silently
 * drops it and the crossing count comes out short for a reason that looks like a
 * bug in the validator rather than in the fixture.
 */
export function assertBumpsInSpan(spec: TraceSpec): void {
  for (const b of spec.bumps) {
    if (b.tStartMs < spec.t0Ms || b.tEndMs > spec.tEndMs) {
      throw new Error(
        `bump ${b.tStartMs}-${b.tEndMs} falls outside the sampled span ` +
          `${spec.t0Ms}-${spec.tEndMs}`,
      );
    }
  }
  for (let i = 1; i < spec.bumps.length; i++) {
    if (spec.bumps[i].tStartMs < spec.bumps[i - 1].tEndMs) {
      throw new Error(`bumps overlap at index ${i}`);
    }
  }
}
