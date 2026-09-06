/// `countReps` — the server's independent recount of the trace.
///
/// This is the second opinion behind I8. The client says "I did 12 reps" in
/// `reps`; the server walks `trace.primary` through its own hysteresis machine
/// and refuses to accept a divergence of more than ±1. That cross-check is only
/// worth anything if the machine here is right, and the two failure modes are
/// both silent: a machine that over-counts flags honest athletes (I13's whole
/// point is that a false positive during a hackathon is worse than a cheat), and
/// one that under-counts lets a fabricated rep list through.
///
/// The tests below are written against the SQUAT thresholds from 0003 —
/// `enterPeak 110`, `enterRest 150`, rest pose 175, decreasing — because those
/// are the numbers the demo actually runs and the ones a regression would hit.

import type { Direction } from "../../supabase/functions/_shared/evidence/schema.ts";
import { countReps } from "../../supabase/functions/_shared/validation/rep_machine.ts";
import { deepStrictEqual, ok, strictEqual, test } from "./_harness.ts";

/** 0003's squat row, resolved against a rest pose of 175°. */
const ENTER_PEAK = 110;
const ENTER_REST = 150;
const DECREASING: Direction = "decreasing";

function squat(signal: number[]) {
  return countReps(signal, ENTER_PEAK, ENTER_REST, DECREASING);
}

// ---------------------------------------------------------------------------
// The basic contract
// ---------------------------------------------------------------------------

test("countReps · a clean dip-and-return is exactly one rep", () => {
  const result = squat([175, 160, 120, 105, 100, 120, 150, 175]);
  deepStrictEqual(result, { reps: 1, finalState: "REST", crossingsToPeak: 1 });
});

test("countReps · an empty signal is zero reps, not an error", () => {
  // A set that was abandoned before the first frame. `crossCheckTrace` compares
  // this against `reps.length`, so zero-on-zero must agree rather than throw.
  deepStrictEqual(squat([]), { reps: 0, finalState: "REST", crossingsToPeak: 0 });
});

test("countReps · a signal that never reaches enterPeak is zero reps", () => {
  // The shallow-squat case: real movement, real effort, but it never crossed the
  // line the calibration says a rep starts at. Counting it would be the engine
  // inventing a rep the athlete did not do.
  const result = squat([175, 160, 130, 125, 130, 160, 175]);
  strictEqual(result.reps, 0);
  strictEqual(result.crossingsToPeak, 0);
  strictEqual(result.finalState, "REST");
});

test("countReps · three consecutive reps count three", () => {
  const result = squat([175, 105, 150, 105, 150, 105, 150]);
  deepStrictEqual(result, { reps: 3, finalState: "REST", crossingsToPeak: 3 });
});

test("countReps · crossingsToPeak equals reps once the athlete has returned to rest", () => {
  // The invariant `crossCheckTrace` leans on: at REST the two counters agree, so
  // a disagreement means the signal ended mid-rep.
  for (let n = 1; n <= 6; n++) {
    const signal: number[] = [175];
    for (let i = 0; i < n; i++) signal.push(100, 155);
    const result = squat(signal);
    strictEqual(result.reps, n, `${n} reps`);
    strictEqual(result.crossingsToPeak, result.reps, `${n} reps`);
    strictEqual(result.finalState, "REST");
  }
});

// ---------------------------------------------------------------------------
// Hysteresis — the reason there are two thresholds and not one
// ---------------------------------------------------------------------------

test("countReps · wobble inside the band does not double-count", () => {
  // The sharpest case in the file. A single-threshold machine reading this signal
  // sees two crossings below 110 and emits two reps; the athlete did one. This
  // is the EMA lag at the turnaround that B3 exists to absorb, and it is the
  // single most common shape in real pose data — nobody holds the bottom of a
  // squat perfectly still.
  const result = squat([175, 108, 112, 108, 112, 150, 175]);
  strictEqual(result.reps, 1, "the band must swallow the 108/112 wobble");
  strictEqual(result.crossingsToPeak, 1);
});

test("countReps · a rep is not emitted until the signal clears enterRest, not enterPeak", () => {
  // 149 is above enterPeak but below enterRest: still inside the band, so still
  // PEAK. Emitting on the way back through enterPeak is exactly the
  // single-threshold bug, and it is why `enterRest` is a distinct number.
  const result = squat([175, 105, 149]);
  strictEqual(result.reps, 0, "149 has not cleared the band");
  strictEqual(result.finalState, "PEAK");

  // And the moment a sample does clear it, the rep lands — including a full
  // return to the rest pose, which is the ordinary way a set ends.
  strictEqual(squat([175, 105, 149, 150]).reps, 1);
  strictEqual(squat([175, 105, 149, 175]).reps, 1);
});

test("countReps · both band edges are inclusive", () => {
  // `<=` and `>=`, not `<` and `>`. A rep whose peak lands exactly on the
  // threshold is a rep; the calibration offset defines the line, not the region
  // beyond it. Getting this wrong would make every romScore of exactly 0.0
  // (peak === enterPeak) also a zero-rep set.
  const exactlyOnBoth = squat([175, ENTER_PEAK, ENTER_REST]);
  deepStrictEqual(exactlyOnBoth, { reps: 1, finalState: "REST", crossingsToPeak: 1 });

  const oneShortOfRest = squat([175, ENTER_PEAK, ENTER_REST - 1]);
  strictEqual(oneShortOfRest.reps, 0);
  strictEqual(oneShortOfRest.finalState, "PEAK");
});

test("countReps · a deep hold at the bottom is still one rep", () => {
  // Pausing at the bottom of a squat is good form, not two reps. The state
  // machine has no notion of duration, which is what makes it immune to an
  // athlete gaming the count by bouncing.
  const signal: number[] = [175, 105];
  for (let i = 0; i < 40; i++) signal.push(98, 102, 100);
  signal.push(155);
  deepStrictEqual(squat(signal), { reps: 1, finalState: "REST", crossingsToPeak: 1 });
});

// ---------------------------------------------------------------------------
// Unfinished reps — no partial credit
// ---------------------------------------------------------------------------

test("countReps · a rep started but never completed counts zero and reports PEAK", () => {
  // The athlete was still at the bottom when the set ended. Scoring nothing for
  // it is correct: `reps` on the client is also emitted only on the return to
  // rest, so both sides agree and the ±1 tolerance is not even needed.
  const result = squat([175, 105, 120]);
  strictEqual(result.reps, 0);
  strictEqual(result.finalState, "PEAK");
  strictEqual(result.crossingsToPeak, 1, "the unfinished entry is still an entry");
});

test("countReps · crossingsToPeak is reps + 1 exactly when the signal ends in PEAK", () => {
  for (let n = 0; n <= 4; n++) {
    const signal: number[] = [175];
    for (let i = 0; i < n; i++) signal.push(100, 155);
    signal.push(100, 130); // start another, do not finish it
    const result = squat(signal);
    strictEqual(result.reps, n);
    strictEqual(result.finalState, "PEAK");
    strictEqual(result.crossingsToPeak, n + 1, `${n} completed reps plus the unfinished one`);
  }
});

// ---------------------------------------------------------------------------
// Direction
// ---------------------------------------------------------------------------

test("countReps · an increasing signal counts symmetrically", () => {
  // Jumping jack: the ratio signal RISES into the rep. REST and PEAK are not
  // "high" and "low" — a pull-up starts extended and flexes upward — so the
  // comparisons have to invert as a pair. A machine that hardcoded `<=` would
  // count zero reps for every jack in the demo and flag the trace as divergent.
  const result = countReps([1.0, 1.3, 1.7, 1.5, 1.7, 1.2, 1.0], 1.6, 1.25, "increasing");
  deepStrictEqual(result, { reps: 1, finalState: "REST", crossingsToPeak: 1 });
});

test("countReps · an increasing signal that never falls back to enterRest is unfinished", () => {
  const result = countReps([1.0, 1.7, 1.4], 1.6, 1.25, "increasing");
  strictEqual(result.reps, 0);
  strictEqual(result.finalState, "PEAK");
});

test("countReps · the same signal read in the opposite direction gives a different answer", () => {
  // Guards the direction actually being consulted rather than the thresholds
  // happening to work either way. Note that `reps` is a poor discriminator here:
  // a squat signal read as increasing still crosses both thresholds twice, just
  // inverted, and lands on the same count. `finalState` and `crossingsToPeak`
  // are what move, so those are what get asserted.
  const atTheBottom = [100, 100, 100];
  deepStrictEqual(squat(atTheBottom), { reps: 0, finalState: "PEAK", crossingsToPeak: 1 });
  deepStrictEqual(
    countReps(atTheBottom, ENTER_PEAK, ENTER_REST, "increasing"),
    { reps: 0, finalState: "REST", crossingsToPeak: 0 },
    "sitting at the bottom of a squat is not at peak for a rising signal",
  );

  // The mirror image at the rest pose.
  const standing = [175, 175, 175];
  deepStrictEqual(squat(standing), { reps: 0, finalState: "REST", crossingsToPeak: 0 });
  deepStrictEqual(
    countReps(standing, ENTER_PEAK, ENTER_REST, "increasing"),
    { reps: 0, finalState: "PEAK", crossingsToPeak: 1 },
    "a rest pose of 175 already satisfies `v >= 110`",
  );
});

test("countReps · 'hold' is never passed here, and would take the increasing branch", () => {
  // `crossCheckTrace` returns before reaching the machine for a holdTime set
  // (there is no peak to cross — a plank has one), so this is unreachable in
  // production. Documented rather than left as an untested fall-through: if the
  // bail-out is ever moved, this is the behaviour that would silently take over.
  const signal = [175, 105, 150];
  deepStrictEqual(
    countReps(signal, ENTER_PEAK, ENTER_REST, "hold"),
    countReps(signal, ENTER_PEAK, ENTER_REST, "increasing"),
    "`isDecreasing('hold')` is false, so 'hold' falls through to the rising comparisons",
  );
});

// ---------------------------------------------------------------------------
// Robustness
// ---------------------------------------------------------------------------

test("countReps · non-finite samples are skipped, not compared", () => {
  // `-Infinity <= 110` is true, so an unguarded comparison would enter PEAK on a
  // dropped frame and then emit a rep when the signal recovers — a rep counted
  // out of a gap in the data. `parseTrace` rejects non-finite values on the way
  // in, but the machine is also handed client-side signals in the replay tests
  // and must not depend on that guard having run.
  const withGarbage = squat([175, Number.NaN, -Infinity, Infinity, 150]);
  deepStrictEqual(withGarbage, { reps: 0, finalState: "REST", crossingsToPeak: 0 });

  // The same signal with a real dip still counts, garbage and all.
  const withGarbageAndARep = squat([175, Number.NaN, 105, -Infinity, 120, 150]);
  strictEqual(withGarbageAndARep.reps, 1);
});

test("countReps · every sample is examined in order, with no lookahead", () => {
  // A long realistic set: 20 reps with a slight drift deepening as fatigue sets
  // in. Written as a loop rather than a literal because the interesting property
  // is that the count tracks the number of cycles and not the signal's shape.
  const signal: number[] = [175];
  for (let i = 0; i < 20; i++) {
    const bottom = 100 - i * 0.5; // drifting deeper
    signal.push(150, 130, bottom, 125, ENTER_REST + 1);
  }
  signal.push(175);
  const result = squat(signal);
  strictEqual(result.reps, 20);
  strictEqual(result.crossingsToPeak, 20);
  ok(result.finalState === "REST");
});
