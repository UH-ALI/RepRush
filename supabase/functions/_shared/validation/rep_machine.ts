/// The two-threshold hysteresis counter, run over an uploaded trace.
///
/// This is deliberately the SIMPLE machine from docs/api-contract.md §The rep
/// state machine, not a port of `lib/features/capture/pipeline/rep_machine.dart`:
///
///     REST  --( primary crosses enterPeak )-->  PEAK      begin tracking
///     PEAK  --( primary crosses enterRest )-->  REST      EMIT A REP
///
/// The Dart machine has four substates, a rising-edge confirmation streak, and a
/// post-emit disarm window. None of those exist to change the count — they exist
/// to drive live feedback while the athlete can still correct, and to absorb EMA
/// lag at the turnaround. Hysteresis alone absorbs the lag for counting purposes;
/// that is what the band is for (B3).
///
/// Porting the four phases here would duplicate a set of tuning constants across
/// the track boundary, and duplicated constants drift by Day 4. The contract
/// asks for threshold crossings counted directly in `trace.primary`, within ±1 of
/// `reps.length` — and that ±1 is exactly the allowance for the two machines not
/// being bit-identical on a pathological signal.

import type { Direction } from "../evidence/schema.ts";
import { isDecreasing } from "../evidence/thresholds.ts";

export type MachineState = "REST" | "PEAK";

export interface CrossingCount {
  reps: number;
  /** Non-REST at the end of the signal: a rep was started but never completed. */
  finalState: MachineState;
  /** Entries into PEAK, including the unfinished one. */
  crossingsToPeak: number;
}

/**
 * Counts reps by walking the signal through the hysteresis band.
 *
 * Direction-aware: for a decreasing signal (squat, push-up, pull-up) entering
 * PEAK means falling to or below `enterPeak`, and for an increasing one (jumping
 * jack) it means rising to or above it. REST and PEAK are not "high" and "low" —
 * a pull-up starts extended and flexes upward.
 */
export function countReps(
  signal: number[],
  enterPeak: number,
  enterRest: number,
  direction: Direction,
): CrossingCount {
  const decreasing = isDecreasing(direction);
  const intoPeak = decreasing ? (v: number) => v <= enterPeak : (v: number) => v >= enterPeak;
  const intoRest = decreasing ? (v: number) => v >= enterRest : (v: number) => v <= enterRest;

  let state: MachineState = "REST";
  let reps = 0;
  let crossingsToPeak = 0;

  for (const v of signal) {
    if (!Number.isFinite(v)) continue;
    if (state === "REST") {
      if (intoPeak(v)) {
        state = "PEAK";
        crossingsToPeak += 1;
      }
    } else if (intoRest(v)) {
      state = "REST";
      reps += 1;
    }
  }

  return { reps, finalState: state, crossingsToPeak };
}
