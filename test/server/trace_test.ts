/// `crossCheckTrace` — I8, the check that makes a forger fake two things at once.
///
/// Recomputing a score from client-supplied measurements satisfies I1, but it is
/// still recomputation from numbers the client chose. This is the only place in
/// the backend where an uploaded representation of the set is compared against a
/// DIFFERENT uploaded representation of the same set, and it is the difference
/// between "trust the measurements" and "trust nothing".
///
/// Two properties dominate the tests below:
///
///   - Every finding is a shadow flag (I13). Nothing here rejects and nothing
///     here changes a score, so a false positive on demo day costs a row in
///     `session_flags` and not a judge's turn.
///   - Holds bail out FIRST, before the missing-trace check. Get that ordering
///     wrong and every honest plank, wall sit and dead hang carries a permanent
///     `info` flag — noise that trains whoever reviews the table to skip `info`,
///     which is exactly where SET_CAPPED and DAILY_CAP_APPLIED live.

import type {
  EvidenceRep,
  EvidenceSet,
  EvidenceTrace,
} from "../../supabase/functions/_shared/evidence/schema.ts";
import { testCatalogue } from "./tools/catalogue.ts";
import {
  type ResolvedThresholds,
  resolveThresholds,
} from "../../supabase/functions/_shared/evidence/thresholds.ts";
import {
  crossCheckTrace,
  MIN_SAMPLES_PER_WINDOW,
  sampleTimes,
  TRACE_REP_TOLERANCE,
} from "../../supabase/functions/_shared/validation/trace.ts";
import {
  type Flag,
  TRACE_INSUFFICIENT,
  TRACE_MISSING,
  TRACE_PEAK_INCONSISTENT,
  TRACE_PEAK_OUT_OF_TOLERANCE,
  TRACE_REP_COUNT_DIVERGENT,
} from "../../supabase/functions/_shared/flags.ts";
import { deepStrictEqual, ok, strictEqual, test } from "./_harness.ts";

const CATALOGUE = testCatalogue();
/** 0003's squat row against a rest pose of 175: enterPeak 110, enterRest 150. */
const REST = 175;
const SQUAT = resolveThresholds(CATALOGUE, "squat", REST);
/** 5 Hz, the contract's downsample rate. */
const HZ = 5;
const STEP = 1000 / HZ;

function thresholds(movementId: string, restSignal = REST): ResolvedThresholds {
  return resolveThresholds(CATALOGUE, movementId, restSignal);
}

/** A rep window, with the peak it claims. */
function rep(i: number, tStartMs: number, tEndMs: number, peakExtreme: number): EvidenceRep {
  return {
    i,
    tStartMs,
    tEndMs,
    restExtreme: REST,
    peakExtreme,
    confMean: 0.9,
    confMin: 0.82,
  };
}

/** Builds a trace whose samples dip to `bottom` inside each rep window. */
function traceFor(
  reps: EvidenceRep[],
  bottom: number,
  startedAtMs = 0,
  endedAtMs = 60_000,
): EvidenceTrace {
  const primary: number[] = [];
  const t0 = startedAtMs;
  for (let t = t0; t <= endedAtMs; t += STEP) {
    const inARep = reps.some((r) => t >= r.tStartMs && t <= r.tEndMs);
    // Inside a window: fall to `bottom` at the midpoint, sit near rest at the
    // edges. Outside: the rest pose. Either way the trace's own extremes are
    // exactly what the test intends them to be.
    if (!inARep) {
      primary.push(REST);
    } else {
      const window = reps.find((r) => t >= r.tStartMs && t <= r.tEndMs)!;
      const mid = (window.tStartMs + window.tEndMs) / 2;
      primary.push(t === mid || Math.abs(t - mid) < STEP ? bottom : REST - 10);
    }
  }
  return { hz: HZ, t0Ms: t0, primary, confMean: primary.map(() => 0.9) };
}

function setWith(reps: EvidenceRep[], trace?: EvidenceTrace, movementId = "squat"): EvidenceSet {
  return {
    movementId,
    measurementType: "repBodyweight",
    startedAtMs: 0,
    endedAtMs: 60_000,
    capture: { fpsMean: 29.4, framesTotal: 1764, framesDropped: 12, modelVariant: "base" },
    calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: REST },
    reps,
    holdSegments: [],
    ...(trace === undefined ? {} : { trace }),
  };
}

function codes(flags: Flag[]): string[] {
  return flags.map((f) => f.code);
}

// ---------------------------------------------------------------------------
// sampleTimes — the trace carries no timestamps, so they are rebuilt
// ---------------------------------------------------------------------------

test("sampleTimes · reconstructs 5 Hz sample times from hz and t0Ms", () => {
  // The parallel-array encoding (I8) is ~10x smaller than an array of objects,
  // which is why time is implicit. Every window lookup below depends on this
  // being right: a wrong step silently shifts all the windows and the
  // cross-check compares the wrong samples to the wrong reps.
  const times = sampleTimes({ hz: 5, t0Ms: 1000, primary: [1, 2, 3, 4] });
  deepStrictEqual(times, [1000, 1200, 1400, 1600]);
});

test("sampleTimes · a fractional hz produces fractional times, and that is fine", () => {
  // 7 Hz does not divide 1000 evenly. Rounding here would drift across a 4000
  // sample trace — by the end the window boundaries would be off by hundreds of
  // milliseconds, enough to attribute a peak to the neighbouring rep.
  const times = sampleTimes({ hz: 7, t0Ms: 0, primary: new Array(4).fill(0) });
  strictEqual(times.length, 4);
  ok(Math.abs(times[1] - 1000 / 7) < 1e-9, `expected 142.857…, got ${times[1]}`);
  ok(Math.abs(times[3] - 3000 / 7) < 1e-9);
});

test("sampleTimes · a trace offset from the set start keeps its offset", () => {
  const times = sampleTimes({ hz: 5, t0Ms: 320, primary: [1, 2] });
  deepStrictEqual(times, [320, 520]);
});

// ---------------------------------------------------------------------------
// The clean path
// ---------------------------------------------------------------------------

test("crossCheckTrace · a consistent trace produces no flags at all", () => {
  // Not "no contradictions" — nothing. A clean set must leave `session_flags`
  // empty, because a flag on every honest submission is indistinguishable from
  // no flagging at all once the reviewer starts skimming.
  const reps = [rep(0, 1000, 3000, 100), rep(1, 5000, 7000, 100)];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  deepStrictEqual(result.flags, []);
  strictEqual(result.traceReps, 2);
  strictEqual(result.repsChecked, 2);
  strictEqual(result.repsInsufficient, 0);
});

test("crossCheckTrace · traceReps is the trace's own count, not the claimed one", () => {
  const reps = [rep(0, 1000, 3000, 100)];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  strictEqual(result.traceReps, 1);
  // The whole point: this number came from `countReps` over `trace.primary` and
  // never looked at `set.reps`.
  ok(result.traceReps !== null);
});

// ---------------------------------------------------------------------------
// Assertion 1 — the claimed peak must be at least as extreme as the trace's
// ---------------------------------------------------------------------------

test("crossCheckTrace · a claimed peak shallower than the trace is a contradiction", () => {
  // 5 Hz can only MISS the true peak, never overshoot it — the client samples at
  // ~15 fps, so it sees strictly more of the movement than the downsample does.
  // A claim of 120 against a trace that bottoms at 100 is therefore not a
  // measurement error. It is physically impossible, which is why this is the one
  // assertion that gets `contradiction` on its own rather than needing a
  // tolerance band.
  const reps = [rep(0, 1000, 3000, 120)];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  deepStrictEqual(codes(result.flags), [TRACE_PEAK_INCONSISTENT]);
  strictEqual(result.flags[0].severity, "contradiction");
  deepStrictEqual(result.flags[0].detail, {
    claimed: 120,
    traceExtreme: 100,
    direction: "decreasing",
  });
  strictEqual(result.flags[0].repIndex, 0);
});

test("crossCheckTrace · a claimed peak deeper than the trace within tolerance is clean", () => {
  // The honest direction: the client saw 96 at full frame rate, the 5 Hz
  // downsample caught 100 on the way past. A 4 degree gap is under the 15 degree
  // tolerance and is exactly what correct downsampling looks like.
  const reps = [rep(0, 1000, 3000, 96)];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  deepStrictEqual(
    result.flags,
    [],
    `a 4° undershoot must not flag, tolerance is ${SQUAT.tolerance}`,
  );
});

test("crossCheckTrace · exactly on the tolerance boundary is clean, one past it is not", () => {
  const tol = SQUAT.tolerance;
  strictEqual(tol, 15, "0003 gives squat a degree signal");

  const atTheEdge = [rep(0, 1000, 3000, 100 - tol)];
  deepStrictEqual(
    crossCheckTrace(setWith(atTheEdge, traceFor(atTheEdge, 100)), 0, SQUAT).flags,
    [],
    "delta === tolerance is `>`, so it passes",
  );

  const justPast = [rep(0, 1000, 3000, 100 - tol - 1)];
  const result = crossCheckTrace(setWith(justPast, traceFor(justPast, 100)), 0, SQUAT);
  deepStrictEqual(codes(result.flags), [TRACE_PEAK_OUT_OF_TOLERANCE]);
  strictEqual(result.flags[0].detail!.delta, tol + 1);
});

// ---------------------------------------------------------------------------
// Assertion 2 — and within tolerance of it
// ---------------------------------------------------------------------------

test("crossCheckTrace · a claimed peak far deeper than the trace is out of tolerance", () => {
  // Satisfies assertion 1 (80 is more extreme than 100) and fails assertion 2.
  // This is the shape the two-assertion split exists for: claiming a 52 degree
  // peak when the trace bottoms at 110 would otherwise pass every check, because
  // "at least as extreme" has no upper bound. It buys formFactor for free — the
  // romScore of a rep that never happened.
  const reps = [rep(0, 1000, 3000, 80)];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  deepStrictEqual(codes(result.flags), [TRACE_PEAK_OUT_OF_TOLERANCE]);
  strictEqual(result.flags[0].severity, "contradiction");
  deepStrictEqual(result.flags[0].detail, {
    claimed: 80,
    traceExtreme: 100,
    delta: 20,
    tolerance: 15,
  });
});

test("crossCheckTrace · the two peak assertions are mutually exclusive per rep", () => {
  // `else if` in the implementation, and deliberately so: a rep that is both
  // shallower than the trace AND out of tolerance is one problem, not two, and
  // double-flagging it would inflate the pattern a human reviews.
  const reps = [rep(0, 1000, 3000, 200)]; // shallower than 100, and 100 away
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  deepStrictEqual(codes(result.flags), [TRACE_PEAK_INCONSISTENT]);
});

test("crossCheckTrace · each rep is judged separately, so one bad rep does not hide another", () => {
  const reps = [
    rep(0, 1000, 3000, 100), // clean
    rep(1, 5000, 7000, 130), // shallower than the trace
    rep(2, 9000, 11000, 80), // deeper than tolerance
  ];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  deepStrictEqual(codes(result.flags), [TRACE_PEAK_INCONSISTENT, TRACE_PEAK_OUT_OF_TOLERANCE]);
  deepStrictEqual(result.flags.map((f) => f.repIndex), [1, 2]);
  strictEqual(result.repsChecked, 3, "the clean rep is still checked, it just does not flag");
});

test("crossCheckTrace · a ratio signal uses the 0.15 tolerance, not 15 degrees", () => {
  // Jumping jack. The tolerance is unit-selected, and getting it wrong here is
  // not subtle: 15 applied to a ratio in [0, 2] is wider than the entire signal
  // range, so assertion 2 could never fire for any jack ever submitted.
  const jack = thresholds("jumping_jack", 1.0);
  strictEqual(jack.unit, "ratio");
  strictEqual(jack.tolerance, 0.15);

  // A claimed peak 0.20 above the trace extreme is out of tolerance for a rising
  // signal, where 0.20 would be nothing at all in degrees.
  const reps: EvidenceRep[] = [{ ...rep(0, 1000, 3000, 1.45), restExtreme: 1.0 }];
  const trace: EvidenceTrace = {
    hz: HZ,
    t0Ms: 0,
    primary: Array.from({ length: 200 }, (_, k) => {
      const t = k * STEP;
      return t >= 1000 && t <= 3000 ? 1.25 : 1.0;
    }),
    confMean: new Array(200).fill(0.9),
  };
  const result = crossCheckTrace(setWith(reps, trace, "jumping_jack"), 0, jack);
  deepStrictEqual(codes(result.flags), [TRACE_PEAK_OUT_OF_TOLERANCE]);
  ok(Math.abs((result.flags[0].detail!.delta as number) - 0.2) < 1e-9);
});

// ---------------------------------------------------------------------------
// Assertion 3 — the whole-set crossing count
// ---------------------------------------------------------------------------

test("crossCheckTrace · a divergence within ±1 is allowed", () => {
  // The tolerance exists because the server's machine is deliberately simpler
  // than the Dart one — two states against four, no confirmation streak, no
  // post-emit disarm. On a pathological signal the two will not be
  // bit-identical, and ±1 is the allowance for that.
  strictEqual(TRACE_REP_TOLERANCE, 1);

  // Two claimed reps against a trace the machine reads as one clean crossing:
  // the second window never returns to enterRest before the set ends.
  const reps = [rep(0, 1000, 3000, 100), rep(1, 5000, 7000, 100)];
  const trace: EvidenceTrace = {
    hz: HZ,
    t0Ms: 0,
    // One full dip, then a second dip that never comes back up.
    primary: [
      ...Array.from({ length: 5 }, () => REST), // 0–800ms, rest
      ...Array.from({ length: 11 }, () => 100), // 1000–3000ms, bottom
      ...Array.from({ length: 9 }, () => REST), // 3200–4800ms, back up
      ...Array.from({ length: 11 }, () => 100), // 5000–7000ms, bottom again
    ],
    confMean: new Array(36).fill(0.9),
  };
  // The machine reads two crossings here, so this is the clean case; the
  // divergent case is the next test.
  const result = crossCheckTrace(setWith(reps, trace), 0, SQUAT);
  strictEqual(result.traceReps, 1, "the second dip never returns to rest, so it is not emitted");
  ok(
    !codes(result.flags).includes(TRACE_REP_COUNT_DIVERGENT),
    `a divergence of 1 is inside the ±${TRACE_REP_TOLERANCE} allowance`,
  );
});

test("crossCheckTrace · a divergence beyond ±1 is a contradiction", () => {
  // Twelve claimed reps against a flat trace. This is the fabrication case: the
  // rep list says a set happened and the time series says nothing moved.
  const reps = Array.from({ length: 12 }, (_, i) => rep(i, 1000 + i * 4000, 3000 + i * 4000, 100));
  const trace: EvidenceTrace = {
    hz: HZ,
    t0Ms: 0,
    primary: new Array(250).fill(REST),
    confMean: new Array(250).fill(0.9),
  };
  const result = crossCheckTrace(setWith(reps, trace), 0, SQUAT);
  strictEqual(result.traceReps, 0);
  const divergent = result.flags.filter((f) => f.code === TRACE_REP_COUNT_DIVERGENT);
  strictEqual(divergent.length, 1, "once per set, not once per rep");
  strictEqual(divergent[0].severity, "contradiction");
  deepStrictEqual(divergent[0].detail, {
    traceReps: 0,
    claimedReps: 12,
    divergence: 12,
    tolerance: TRACE_REP_TOLERANCE,
  });
  strictEqual(divergent[0].repIndex, undefined, "this is a set-scoped finding");
  strictEqual(divergent[0].setIndex, 0);
});

test("crossCheckTrace · a trace claiming more reps than the summary also diverges", () => {
  // The check is `Math.abs`, so it is symmetric. An inflated trace with an
  // honest rep list is a stranger case but the same contradiction, and a
  // one-directional comparison would let a client pad the trace to hide a
  // truncated rep list.
  const reps = [rep(0, 1000, 3000, 100)];
  const primary: number[] = [];
  for (let i = 0; i < 8; i++) {
    primary.push(...new Array(5).fill(REST), ...new Array(6).fill(100));
  }
  const trace: EvidenceTrace = {
    hz: HZ,
    t0Ms: 0,
    primary,
    confMean: new Array(primary.length).fill(0.9),
  };
  const result = crossCheckTrace(setWith(reps, trace), 0, SQUAT);
  strictEqual(result.traceReps, 7, "eight dips, the last never returning to rest");
  const divergent = result.flags.filter((f) => f.code === TRACE_REP_COUNT_DIVERGENT);
  strictEqual(divergent.length, 1);
  strictEqual(divergent[0].detail!.claimedReps, 1);
});

test("crossCheckTrace · a set-scoped divergence is reported even when every rep window is clean", () => {
  // The three assertions are independent. Here every claimed rep matches its own
  // window exactly, and the set still contradicts — because the trace contains
  // two dips the rep list never claims. The numbers are all real; there are just
  // more of them in the time series than in the summary.
  //
  // Building it the other way round (more claimed reps than trace dips) cannot
  // isolate assertion 3: an unclaimed rep window finds the trace sitting at the
  // rest pose and trips OUT_OF_TOLERANCE first. Extra movement outside every
  // window is the only shape that reaches the count check alone.
  const claimed = [rep(0, 1000, 3000, 100), rep(1, 5000, 7000, 100)];
  const unclaimed = [rep(2, 20000, 22000, 100), rep(3, 24000, 26000, 100)];
  const trace = traceFor([...claimed, ...unclaimed], 100);

  const result = crossCheckTrace(setWith(claimed, trace), 0, SQUAT);
  deepStrictEqual(
    codes(result.flags),
    [TRACE_REP_COUNT_DIVERGENT],
    `expected only the count divergence, got ${codes(result.flags).join(", ")}`,
  );
  strictEqual(result.repsChecked, 2, "both claimed reps were checked and both passed");
  deepStrictEqual(result.flags[0].detail, {
    traceReps: 4,
    claimedReps: 2,
    divergence: 2,
    tolerance: TRACE_REP_TOLERANCE,
  });
});

// ---------------------------------------------------------------------------
// Insufficient samples
// ---------------------------------------------------------------------------

test("crossCheckTrace · too few samples in a window warns and skips the peak assertions", () => {
  // With one sample there is no extreme to compare against — the "extreme" of a
  // single point is that point, and asserting on it would flag whatever the
  // downsample happened to land on. `warn`, not `contradiction`: a sparse window
  // is a capture-quality problem, not evidence of dishonesty.
  strictEqual(MIN_SAMPLES_PER_WINDOW, 2);

  // One rep window 100ms wide at 5 Hz: samples land at 0, 200, 400…, so exactly
  // one (t=1000) falls inside [1000, 1100]. One is below the minimum of two.
  const reps = [rep(0, 1000, 1100, 100)];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  deepStrictEqual(codes(result.flags).filter((c) => c !== TRACE_REP_COUNT_DIVERGENT), [
    TRACE_INSUFFICIENT,
  ]);
  strictEqual(result.repsInsufficient, 1);
  strictEqual(result.repsChecked, 0, "an insufficient rep is not a checked rep");
  const insufficient = result.flags.find((f) => f.code === TRACE_INSUFFICIENT)!;
  strictEqual(insufficient.severity, "warn");
  deepStrictEqual(insufficient.detail, { samplesInWindow: 1, tStartMs: 1000, tEndMs: 1100 });
  strictEqual(insufficient.repIndex, 0);
});

test("crossCheckTrace · exactly MIN_SAMPLES_PER_WINDOW samples is enough to assert", () => {
  // 400ms at 5 Hz puts samples at 1000 and 1200 inside a [1000, 1200] window —
  // both bounds inclusive, which is what makes two.
  const reps = [rep(0, 1000, 1200, 100)];
  const result = crossCheckTrace(setWith(reps, traceFor(reps, 100)), 0, SQUAT);
  ok(
    !codes(result.flags).includes(TRACE_INSUFFICIENT),
    `two samples is enough, got ${codes(result.flags).join(", ")}`,
  );
  strictEqual(result.repsChecked, 1);
});

test("crossCheckTrace · a sparse set still gets its crossing count", () => {
  // Insufficient samples skip the per-rep peak assertions but the whole-set
  // crossing count runs regardless — it reads `trace.primary` end to end and
  // does not care how the samples fall against the rep windows. Skipping it too
  // would make a low frame rate an easy way to dodge assertion 3 entirely.
  const reps = Array.from({ length: 10 }, (_, i) => rep(i, i * 100, i * 100 + 50, 100));
  const trace: EvidenceTrace = {
    hz: HZ,
    t0Ms: 0,
    primary: new Array(100).fill(REST),
    confMean: new Array(100).fill(0.9),
  };
  const result = crossCheckTrace(setWith(reps, trace), 0, SQUAT);
  strictEqual(result.repsInsufficient, 10);
  strictEqual(result.repsChecked, 0);
  ok(result.traceReps !== null, "the crossing count ran even though no window was checkable");
  ok(codes(result.flags).includes(TRACE_REP_COUNT_DIVERGENT));
});

// ---------------------------------------------------------------------------
// Missing trace — the state the backend actually ships in
// ---------------------------------------------------------------------------

test("crossCheckTrace · no trace on a rep set is exactly one info flag", () => {
  // Track A does not emit a contract-shaped trace yet, so this is the path every
  // real submission takes today. `info` and not a rejection is what makes the
  // backend deployable before Seam 1 closes — a hard requirement here would
  // block the whole demo on a recorder that does not exist.
  const reps = [rep(0, 1000, 3000, 100)];
  const result = crossCheckTrace(setWith(reps, undefined), 0, SQUAT);
  deepStrictEqual(result.flags, [{ code: TRACE_MISSING, severity: "info", setIndex: 0 }]);
  strictEqual(
    result.traceReps,
    null,
    "nothing was counted, which is not the same as counting zero",
  );
  strictEqual(result.repsChecked, 0);
});

test("crossCheckTrace · a missing trace never fabricates a divergence", () => {
  // `traceReps: null` must not be coerced to 0 and compared against
  // `reps.length`, or every traceless 12-rep set would carry a contradiction
  // flag — and I13's shadow-flag policy would be flagging the entire demo.
  const reps = Array.from({ length: 12 }, (_, i) => rep(i, i * 4000, i * 4000 + 2000, 100));
  const result = crossCheckTrace(setWith(reps, undefined), 0, SQUAT);
  strictEqual(result.flags.length, 1);
  strictEqual(result.flags[0].code, TRACE_MISSING);
});

// ---------------------------------------------------------------------------
// Holds — the ordering that keeps honest planks clean
// ---------------------------------------------------------------------------

test("crossCheckTrace · a holdTime set with no trace produces zero flags", () => {
  // THE ORDERING TEST. The hold bail-out is before the missing-trace check, so a
  // plank that carries no trace is not merely "not contradicted" — it is
  // silent. Reversing those two branches would put a TRACE_MISSING info flag on
  // every honest plank, wall sit and dead hang in the product, forever.
  const plank: EvidenceSet = {
    movementId: "plank",
    measurementType: "holdTime",
    startedAtMs: 0,
    endedAtMs: 62_000,
    capture: { fpsMean: 29.1, framesTotal: 1804, framesDropped: 9, modelVariant: "base" },
    calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: 172.5 },
    reps: [],
    holdSegments: [{ tStartMs: 1000, tEndMs: 61_000, meanSignal: 172.5, confMean: 0.88 }],
  };
  const result = crossCheckTrace(plank, 0, thresholds("plank", 172.5));
  deepStrictEqual(result.flags, []);
  strictEqual(result.traceReps, null);
});

test("crossCheckTrace · a holdTime set that DOES carry a trace is still silent", () => {
  // A hold has no state machine and no reps, so there is nothing for a trace to
  // be cross-checked against: the in-form band already gated accrual upstream
  // and the segment timings are the summary. Assertions 1–3 are all rep-shaped.
  const plank: EvidenceSet = {
    movementId: "plank",
    measurementType: "holdTime",
    startedAtMs: 0,
    endedAtMs: 62_000,
    capture: { fpsMean: 29.1, framesTotal: 1804, framesDropped: 9, modelVariant: "base" },
    calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: 172.5 },
    reps: [],
    holdSegments: [{ tStartMs: 1000, tEndMs: 61_000, meanSignal: 172.5, confMean: 0.88 }],
    // A trace that contradicts nothing in particular — the point is that it is
    // never looked at.
    trace: {
      hz: HZ,
      t0Ms: 0,
      primary: new Array(310).fill(120),
      confMean: new Array(310).fill(0.9),
    },
  };
  const result = crossCheckTrace(plank, 0, thresholds("plank", 172.5));
  deepStrictEqual(result.flags, []);
  strictEqual(result.repsChecked, 0);
});

test("crossCheckTrace · dead_hang is silent, and stays silent if its direction is wrong", () => {
  // THE REGRESSION TEST. 0003's family backfill gives every `pull` movement the
  // family's tier-2 offsets, and `dead_hang` is tier 1 in `pull` — so it
  // inherited `direction='decreasing'`, which ran an honest dead hang through the
  // crossing count against an EMPTY rep list. Any trace with a single dip
  // diverges from zero reps and fabricates TRACE_REP_COUNT_DIVERGENT on a set
  // that is doing everything right.
  //
  // The migration now lists dead_hang explicitly, which is the fix:
  const hang = thresholds("dead_hang");
  strictEqual(hang.movement.measurementType, "holdTime");
  strictEqual(hang.direction, "hold", "0003 lists dead_hang explicitly to override the backfill");

  const set: EvidenceSet = {
    movementId: "dead_hang",
    measurementType: "holdTime",
    startedAtMs: 0,
    endedAtMs: 45_000,
    capture: { fpsMean: 28.8, framesTotal: 1296, framesDropped: 20, modelVariant: "base" },
    calibration: { torsoLengthPx: 420, shoulderWidthPx: 260, restSignal: 168 },
    reps: [],
    holdSegments: [{ tStartMs: 500, tEndMs: 44_000, meanSignal: 168, confMean: 0.84 }],
    // A trace with plenty of crossings, which is what would have been counted.
    trace: {
      hz: HZ,
      t0Ms: 0,
      primary: Array.from({ length: 225 }, (_, k) => (k % 20 < 10 ? 168 : 100)),
      confMean: new Array(225).fill(0.84),
    },
  };
  deepStrictEqual(
    crossCheckTrace(set, 0, hang).flags,
    [],
    "a dead hang with a busy trace must be silent",
  );

  // But the fix living in the migration is not enough on its own: the next
  // holdTime movement added to a family will inherit that family's direction
  // again unless someone remembers to list it. So the bail-out is keyed off
  // `measurementType` OR `direction` — `measurementType` being the authoritative
  // statement that there is no rep state machine, and `direction` a property of a
  // versioned offsets row that a seeding slip can get wrong.
  //
  // Reconstructing the pre-fix state directly, rather than hoping the migration
  // stays broken, is what makes this a guard instead of a snapshot:
  const preFix: ResolvedThresholds = { ...hang, direction: "decreasing" };
  const result = crossCheckTrace(set, 0, preFix);
  deepStrictEqual(
    result.flags,
    [],
    "measurementType alone must silence a hold, whatever direction the row says",
  );
  strictEqual(result.traceReps, null, "the crossing count must never have run");
});

test("crossCheckTrace · a direction of 'hold' bails out even on a repBodyweight set", () => {
  // The second half of the OR. A set whose measurementType says repBodyweight but
  // whose resolved direction is 'hold' is a contradictory catalogue, and running
  // the rep assertions against it would produce nonsense rather than a useful
  // signal. Bail out on either being wrong.
  const reps = [rep(0, 1000, 3000, 100)];
  const mismatched: ResolvedThresholds = { ...SQUAT, direction: "hold" };
  const result = crossCheckTrace(setWith(reps, undefined), 0, mismatched);
  deepStrictEqual(result.flags, []);
  strictEqual(result.traceReps, null);
});

// ---------------------------------------------------------------------------
// Set index plumbing
// ---------------------------------------------------------------------------

test("crossCheckTrace · every flag carries the setIndex it was handed", () => {
  // Flags from all the sets in a submission land in one `session_flags` table.
  // A finding with no setIndex, or the wrong one, cannot be acted on — the human
  // reviewing it has no way to find the set it describes.
  const reps = Array.from({ length: 12 }, (_, i) => rep(i, i * 4000, i * 4000 + 2000, 100));
  const trace: EvidenceTrace = {
    hz: HZ,
    t0Ms: 0,
    primary: new Array(250).fill(REST),
    confMean: new Array(250).fill(0.9),
  };
  for (const setIndex of [0, 2, 7]) {
    const result = crossCheckTrace(setWith(reps, trace), setIndex, SQUAT);
    ok(result.flags.length > 0, `setIndex ${setIndex} should have flagged`);
    for (const f of result.flags) {
      strictEqual(f.setIndex, setIndex, `${f.code} carries the wrong setIndex`);
    }
  }
});

test("crossCheckTrace · the same set at two indexes produces identical findings", () => {
  // Nothing may depend on position in `evidence.sets`. The cursor is reset per
  // call and the thresholds come from the movement, not the index.
  const reps = [rep(0, 1000, 3000, 130), rep(1, 5000, 7000, 100)];
  const set = setWith(reps, traceFor(reps, 100));
  const a = crossCheckTrace(set, 0, SQUAT);
  const b = crossCheckTrace(set, 3, SQUAT);
  // Compared with setIndex stripped, since that is the one field meant to differ.
  const strip = (flags: Flag[]) => flags.map((f) => ({ ...f, setIndex: undefined }));
  deepStrictEqual(strip(a.flags), strip(b.flags));
  strictEqual(a.traceReps, b.traceReps);
  strictEqual(a.repsChecked, b.repsChecked);
  strictEqual(a.repsInsufficient, b.repsInsufficient);
});
