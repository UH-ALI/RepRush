/// The fixture set — ten scenarios, each isolating exactly one behaviour of the
/// scoring engine or a validator.
///
/// WHAT A FIXTURE IS
/// A complete submission context, not just a payload:
///
///   `evidence`  the wire body, byte-for-byte what a client POSTs to
///               `/session/submit`. `parseEvidence` must accept it verbatim.
///   `session`   the `workout_sessions` row the server already holds. The Class-1
///               gates compare the two, so a fixture that only carried the
///               payload could not exercise a gate at all.
///   `submitAtMs` the server's arrival stamp. Fixed per fixture — nothing here
///               reads a clock, which is what makes the goldens reproducible.
///   `context`   unlocked movements and today's banked RepScore, i.e. everything
///               `ScoreContext` needs that is not on the wire.
///
/// WHY ONE BEHAVIOUR PER FIXTURE
/// A golden is only useful if a reader can say why a number is what it is. A
/// fixture that trips four unrelated penalties produces a formFactor nobody can
/// check by hand, so a regression in it reads as noise. Each `about` string names
/// the one thing under test; the flags in its golden should be explicable from
/// that sentence alone.
///
/// THRESHOLD LITERALS BELOW ARE A COPY, AND A TEST PINS THE COPY
/// `SQUAT`, `PULL_UP` and `PLANK` restate `restSignal + offset` from
/// `supabase/migrations/0003_config_versions.sql` so a spec can say `peak: 82`
/// instead of forcing the reader to do the arithmetic. That is a duplication
/// hazard, so `thresholds_test.ts` resolves the real catalogue and asserts these
/// literals against it — editing the migration without editing this file fails a
/// test rather than silently invalidating every golden.

import type {
  Evidence,
  EvidenceHoldSegment,
  EvidenceRep,
  EvidenceSet,
  MeasurementType,
} from "../../../supabase/functions/_shared/evidence/schema.ts";
import {
  SESSION_EXPIRY_MS,
  type SessionRow,
} from "../../../supabase/functions/_shared/validation/session.ts";
import {
  CV_HEALTHY,
  FATIGUE_SLOPE_HEALTHY,
  IMPOSSIBLE_CYCLE_MS,
  tempoFromReps,
  type TempoStats,
} from "../../../supabase/functions/_shared/scoring/tempo.ts";
import { assertBumpsInSpan, type Bump, bumpsFromReps, makeTrace } from "./make_trace.ts";
import { fix, wobble } from "./rand.ts";

// ---------------------------------------------------------------------------
// Shared scenario constants
// ---------------------------------------------------------------------------

/** Must match `movement_config_versions.version` in 0003 and `DemoVenue`. */
export const CONFIG_VERSION = "2026-08-30.1";

/**
 * Fixed epoch for every fixture: 2026-09-05T09:00:00Z. `Date.UTC` rather than a
 * parsed ISO string so there is no timezone ambiguity in how it was built, and
 * `utcDay()` of it is "2026-09-05" on any machine.
 */
export const SESSION_START_MS = Date.UTC(2026, 8, 5, 9, 0, 0);

/** The demo venue — matches `VENUE` in `_shared/stubs/venue.ts`. */
export const VENUE = { lat: 51.5074, lng: -0.1278 } as const;

/**
 * Res-8 index for the venue — the same cell `VENUE.hexH3` carries in
 * `_shared/stubs/venue.ts` and `DemoVenue.demoHexH3` carries in the Dart stub.
 *
 * This literal was fabricated for most of the build, with a note to regenerate it
 * "the first time the suite runs under Deno", because `_shared/h3.ts` imports
 * `npm:h3-js` and nothing could execute it. That has now been done: the value is
 * `latLngToCell(51.5074, -0.1278, 8)`, cross-checked against what the live
 * `session-start` route returns for the same coordinates.
 *
 * Worth recording what the fabrication cost: the invented index was res-10, not
 * res-8. A made-up hex string does not even reliably land in the resolution you
 * meant it to, which is the argument for computing one over writing a
 * plausible-looking one.
 *
 * No gate reads it and no score depends on it — it exists so a fixture's session
 * row has the same shape as a real one.
 */
export const VENUE_H3 = "88195da49bfffff";

export const USER_ID = "11111111-1111-4111-8111-111111111111";

/**
 * Tier 1 and 2 are granted at signup (I10), so this is every movement in 0002
 * whose tier is 1 or 2. `pistol_squat` is deliberately absent — see
 * `squat_plus_locked_pistol`.
 */
export const UNLOCKED_AT_SIGNUP: readonly string[] = [
  "assisted_squat",
  "squat",
  "knee_push_up",
  "push_up",
  "dead_hang",
  "pull_up",
  "wall_sit",
  "plank",
  "jumping_jack",
];

/** Trace rate the contract asks for (I8). */
export const TRACE_HZ = 5;

/** Offset of the first rep from session start — the 3-2-1 countdown plus a beat. */
const FIRST_REP_MS = 3500;
/** The set window opens this far before the first rep. */
const SET_LEAD_IN_MS = 500;
/** The set window closes this far after the last rep. */
const SET_LEAD_OUT_MS = 500;

// ---------------------------------------------------------------------------
// Threshold literals — see the pinning note in the file header
// ---------------------------------------------------------------------------

/** squat: rest 175, offsets -65 / -25 / -95, deg, decreasing. */
export const SQUAT = {
  id: "squat",
  measurementType: "repBodyweight" as MeasurementType,
  difficulty: 1.0,
  tier: 2,
  rest: 175,
  enterPeak: 110,
  enterRest: 150,
  romTarget: 80,
};

/** pull_up: rest 175, offsets -85 / -25 / -120, deg, decreasing. */
export const PULL_UP = {
  id: "pull_up",
  measurementType: "repBodyweight" as MeasurementType,
  difficulty: 1.8,
  tier: 2,
  rest: 175,
  enterPeak: 90,
  enterRest: 150,
  romTarget: 55,
};

/** pistol_squat: T4, inherits the squat family's offsets via 0003's lateral join. */
export const PISTOL_SQUAT = { ...SQUAT, id: "pistol_squat", difficulty: 2.4, tier: 4 };

/** plank: holdTime, in-form band 160–185, rest 178. Offsets are placeholders. */
export const PLANK = {
  id: "plank",
  measurementType: "holdTime" as MeasurementType,
  difficulty: 1.0,
  tier: 2,
  rest: 178,
  bandLow: 160,
  bandHigh: 185,
};

// ---------------------------------------------------------------------------
// Rep timeline builder
// ---------------------------------------------------------------------------

/**
 * A cycle pattern whose tempo statistics are computable rather than emergent.
 *
 *     cycle(i) = baseMs + driftMs * i + weaveMs * ((i % 4) - 1.5)
 *
 * WHY NOT A HASH
 * The first version of this used `wobble` for the cycle spread, on the reasoning
 * that pseudo-random jitter looks human. It does not survive contact with a
 * threshold. `wobble` is a hash, so for any given seed its output over a short
 * run can correlate with the linear drift and *cancel* it: at five reps the
 * pistol-squat set came out with cycleCv 0.017 against a CV_HEALTHY of 0.06 and
 * silently acquired a TEMPO_UNIFORM flag nobody intended. Tuning the seed until
 * the number cleared the bar is fitting a fixture to a hash output, and it breaks
 * again the moment the seed or the count changes.
 *
 * The `(i % 4) - 1.5` weave is mean-zero over every fourth rep and has a fixed
 * standard deviation of `weaveMs * sqrt(1.25)`, so the spread is a property of the
 * parameters and not of a lucky draw. `driftMs` supplies the fatigue slope. Both
 * are then verified against the real `tempoFromReps` by [assertTempoIntent].
 */
export interface TempoShape {
  /** Cycle length of rep zero. */
  baseMs: number;
  /** Added per rep — the slowdown a human set accrues. */
  driftMs: number;
  /** Half-spread of the four-step weave — the rep-to-rep variation. */
  weaveMs: number;
}

export function cycleFrom(shape: TempoShape): (i: number) => number {
  return (i) => shape.baseMs + shape.driftMs * i + shape.weaveMs * ((i % 4) - 1.5);
}

/** What a fixture claims the tempo terms will do with it. */
export type TempoIntent =
  /** Neither penalty fires: spread and drift are both comfortably healthy. */
  | "healthy"
  /** Uniformity fires and the drift term does not. */
  | "uniform"
  /** Median cycle is below the human floor; tempoFactor is forced to 0.5. */
  | "impossible";

export interface RepPlan {
  count: number;
  /** `tEndMs - tStartMs` for rep `i`. This is what the tempo terms read. */
  cycleMs: (i: number) => number;
  /**
   * Declared, then verified by [buildSet]. Required rather than defaulted so a
   * new fixture cannot quietly omit it and inherit whatever its cycles happen to
   * do.
   */
  tempo: TempoIntent;
  /** `reps[i].tStartMs - reps[i-1].tEndMs`. I6's floor is 400 ms. */
  gapMs: (i: number) => number;
  /** Claimed peak extreme, in absolute signal units. */
  peak: (i: number) => number;
  confMean?: (i: number) => number;
  /** B18 — normalised by shoulder width. Omit and nothing is docked. */
  hipDriftNorm?: (i: number) => number;
  /** B16 — normalised by torso length. Only read for `pull_up`. */
  shoulderWristDyNorm?: (i: number) => number;
  /** Absolute `tStartMs` of rep zero. Defaults to [FIRST_REP_MS]. */
  firstStartMs?: number;
}

/**
 * Lays reps end to end from a plan. Integer milliseconds throughout, because
 * `parseEvidence` requires `tStartMs`/`tEndMs` to be integers and a fractional
 * cycle would otherwise surface as a parser rejection rather than as the tempo
 * behaviour the fixture was written to show.
 */
export function buildReps(plan: RepPlan, restSignal: number): EvidenceRep[] {
  const reps: EvidenceRep[] = [];
  let cursor = plan.firstStartMs ?? FIRST_REP_MS;

  for (let i = 0; i < plan.count; i++) {
    if (i > 0) cursor += Math.round(plan.gapMs(i));
    const tStartMs = Math.round(cursor);
    const cycle = Math.round(plan.cycleMs(i));
    const tEndMs = tStartMs + cycle;

    const confMean = fix(plan.confMean?.(i) ?? 0.9, 3);
    // The descent is the eccentric phase for a squat/push-up and the ascent for a
    // pull-up; nothing scores the split, so a fixed 55/45 is enough to make the
    // field present and plausible.
    const eccentricMs = Math.round(cycle * 0.55);

    const rep: EvidenceRep = {
      i,
      tStartMs,
      tEndMs,
      restExtreme: restSignal,
      peakExtreme: fix(plan.peak(i), 2),
      confMean,
      confMin: fix(Math.max(0.3, confMean - 0.08), 3),
      concentricMs: cycle - eccentricMs,
      eccentricMs,
    };
    if (plan.hipDriftNorm) rep.hipDriftNorm = fix(plan.hipDriftNorm(i), 3);
    if (plan.shoulderWristDyNorm) {
      rep.shoulderWristDyNorm = fix(plan.shoulderWristDyNorm(i), 3);
    }

    reps.push(rep);
    cursor = tEndMs;
  }

  return reps;
}

// ---------------------------------------------------------------------------
// Set builder
// ---------------------------------------------------------------------------

export type TracePlan =
  /** Nothing on the wire — the state Track A is in today. Costs an `info` flag. */
  | { kind: "none" }
  /** One bump per rep at its claimed extreme: the two representations agree. */
  | { kind: "consistent" }
  /**
   * Bumps derived from the built rep list. A function rather than a literal
   * array because a bump's window has to be the rep's window, and the rep
   * timeline does not exist until `buildSet` has laid it out — a literal would
   * mean building the set twice and patching a trace onto the first result.
   */
  | { kind: "custom"; bumps: (reps: readonly EvidenceRep[]) => readonly Bump[] };

export interface HoldPlan {
  /** Absolute, on the same offset clock as the reps. */
  tStartMs: number;
  tEndMs: number;
  meanSignal: number;
  confMean: number;
}

export interface SetPlan {
  movementId: string;
  measurementType: MeasurementType;
  restSignal: number;
  torsoLengthPx?: number;
  shoulderWidthPx?: number;
  /** Required for a `repBodyweight` set; the parser rejects reps and segments
   *  appearing together, so exactly one of the two is ever populated. */
  reps?: RepPlan;
  holdSegments?: readonly HoldPlan[];
  trace?: TracePlan;
  /** Reconciliation only; a mismatch is a `warn` flag, never a corrected count. */
  clientRepCount?: number;
  fpsMean?: number;
}

export interface BuiltSet {
  set: EvidenceSet;
  /** Set window, so a caller can place a second set after this one. */
  startedAtMs: number;
  endedAtMs: number;
  /** Empty for a `holdTime` set. */
  reps: EvidenceRep[];
  /** Null for a `holdTime` set — there is no cadence to measure. */
  tempo: TempoStats | null;
}

/**
 * Checks a built set's tempo against what its plan claimed, and throws with the
 * actual numbers if they disagree.
 *
 * This is not a test of `tempoFromReps` — that is `tempo_test.ts`'s job, against
 * literals. It is a test of the FIXTURE: "I wrote this plan to be tempo-healthy"
 * is an assumption, and an unverified assumption in a fixture becomes an
 * unexplained extra flag in a golden. Asking the real implementation and refusing
 * the answer if it contradicts the plan turns that into a build error naming cv
 * and slope.
 *
 * It is also the early-warning system for a retuned threshold: raise CV_HEALTHY
 * and every `"healthy"` fixture fails here at generation time, rather than each
 * golden silently regenerating with a new TEMPO_UNIFORM in it.
 */
function assertTempoIntent(plan: RepPlan, tempo: TempoStats): void {
  const describe = `cycleCv ${tempo.cycleCv === null ? "n/a" : tempo.cycleCv.toFixed(4)} ` +
    `(healthy >= ${CV_HEALTHY}), fatigueSlope ` +
    `${tempo.fatigueSlope === null ? "n/a" : tempo.fatigueSlope.toFixed(4)} ` +
    `(healthy >= ${FATIGUE_SLOPE_HEALTHY}), medianCycleMs ` +
    `${tempo.medianCycleMs} (floor ${IMPOSSIBLE_CYCLE_MS})`;

  switch (plan.tempo) {
    case "healthy":
      if (tempo.impossibleCadence) {
        throw new Error(
          `${plan.count} reps declared tempo-healthy but the cadence is impossible: ${describe}`,
        );
      }
      if (tempo.uniformityPenalty !== 0 || tempo.fatiguePenalty !== 0) {
        throw new Error(
          `${plan.count} reps declared tempo-healthy but a tempo penalty fired ` +
            `(uniformity ${tempo.uniformityPenalty}, fatigue ${tempo.fatiguePenalty}): ${describe}`,
        );
      }
      return;
    case "uniform":
      if (tempo.uniformityPenalty <= 0) {
        throw new Error(
          `${plan.count} reps declared uniform but no uniformity penalty fired: ${describe}`,
        );
      }
      if (tempo.fatiguePenalty !== 0) {
        throw new Error(
          `${plan.count} reps declared uniform-only but the fatigue term also fired — ` +
            `a set this size cannot separate the two penalties: ${describe}`,
        );
      }
      if (tempo.impossibleCadence) {
        throw new Error(
          `${plan.count} reps declared uniform but the cadence is impossible: ${describe}`,
        );
      }
      return;
    case "impossible":
      if (!tempo.impossibleCadence) {
        throw new Error(
          `${plan.count} reps declared impossible but the median cycle is legal: ${describe}`,
        );
      }
      return;
  }
}

export function buildSet(plan: SetPlan): BuiltSet {
  const isHold = plan.measurementType === "holdTime";
  const fpsMean = plan.fpsMean ?? 29.4;

  let reps: EvidenceRep[] = [];
  let holdSegments: EvidenceHoldSegment[] = [];

  if (isHold) {
    if (!plan.holdSegments || plan.holdSegments.length === 0) {
      throw new Error(`${plan.movementId}: a holdTime set needs at least one segment`);
    }
    holdSegments = plan.holdSegments.map((s) => ({
      tStartMs: s.tStartMs,
      tEndMs: s.tEndMs,
      meanSignal: s.meanSignal,
      confMean: s.confMean,
    }));
  } else {
    if (!plan.reps) {
      throw new Error(`${plan.movementId}: a repBodyweight set needs a rep plan`);
    }
    reps = buildReps(plan.reps, plan.restSignal);
  }

  // Asked of the real implementation, here, rather than inferred from the plan's
  // parameters and left for the golden to reveal. The tempo terms are the one
  // part of a fixture whose behaviour cannot be read off its inputs at a glance,
  // so an unverified assumption becomes an unexplained extra flag downstream.
  const tempo = reps.length > 0 ? tempoFromReps(reps) : null;
  if (plan.reps && tempo !== null) assertTempoIntent(plan.reps, tempo);

  const firstMs = isHold ? holdSegments[0].tStartMs : reps[0].tStartMs;
  const lastMs = isHold
    ? holdSegments[holdSegments.length - 1].tEndMs
    : reps[reps.length - 1].tEndMs;
  const startedAtMs = firstMs - SET_LEAD_IN_MS;
  const endedAtMs = lastMs + SET_LEAD_OUT_MS;

  const framesTotal = Math.round(((endedAtMs - startedAtMs) / 1000) * fpsMean);

  const set: EvidenceSet = {
    movementId: plan.movementId,
    measurementType: plan.measurementType,
    startedAtMs,
    endedAtMs,
    capture: {
      fpsMean,
      framesTotal,
      // A 2 % drop rate is what a warm phone in a gym manages; nothing scores it.
      framesDropped: Math.round(framesTotal * 0.02),
      modelVariant: "base",
    },
    calibration: {
      torsoLengthPx: plan.torsoLengthPx ?? 420,
      shoulderWidthPx: plan.shoulderWidthPx ?? 260,
      restSignal: plan.restSignal,
    },
    reps,
    holdSegments,
    clientRepCount: plan.clientRepCount ?? (reps.length > 0 ? reps.length : undefined),
  };

  const tracePlan = plan.trace ?? { kind: "none" };
  if (tracePlan.kind !== "none") {
    const bumps = tracePlan.kind === "consistent" ? bumpsFromReps(reps) : tracePlan.bumps(reps);
    const spec = {
      hz: TRACE_HZ,
      t0Ms: startedAtMs,
      tEndMs: endedAtMs,
      restSignal: plan.restSignal,
      bumps,
      confMean: 0.9,
    };
    // Fail in the generator, not as a mysterious flag in the golden.
    assertBumpsInSpan(spec);
    set.trace = makeTrace(spec);
  }

  return { set, startedAtMs, endedAtMs, reps, tempo };
}

/** A bump aligned to one of a built set's reps but at a different depth. */
export function bumpAt(reps: readonly EvidenceRep[], index: number, depth: number): Bump {
  const rep = reps[index];
  if (!rep) throw new Error(`no rep at index ${index}`);
  return { tStartMs: rep.tStartMs, tEndMs: rep.tEndMs, depth };
}

// ---------------------------------------------------------------------------
// Fixture assembly
// ---------------------------------------------------------------------------

export interface FixtureContext {
  userId: string;
  unlocked: readonly string[];
  /** RepScore already banked today — the input to the diminishing-returns cap. */
  alreadyEarnedToday: number;
}

export interface Fixture {
  /** One paragraph: what is under test and what the golden should show. */
  about: string;
  evidence: Evidence;
  session: SessionRow;
  submitAtMs: number;
  context: FixtureContext;
}

export interface ScenarioInput {
  about: string;
  sets: readonly BuiltSet[];
  spotId?: string | null;
  /**
   * Overrides the arrival stamp. Defaults to `lastSetEnd + 5 s`, which always
   * satisfies the wall-clock gate; the replay fixture sets it explicitly to
   * something that does not.
   */
  submitAtMs?: number;
  unlocked?: readonly string[];
  alreadyEarnedToday?: number;
}

function sessionRow(
  sessionId: string,
  startMs: number,
  spotId: string | null,
): SessionRow {
  return {
    id: sessionId,
    user_id: USER_ID,
    status: "open",
    movement_config_version: CONFIG_VERSION,
    server_start_ms: startMs,
    submitted_at_ms: null,
    expires_at_ms: startMs + SESSION_EXPIRY_MS,
    start_lat: VENUE.lat,
    start_lng: VENUE.lng,
    start_accuracy_m: 8,
    start_is_mocked: false,
    start_h3: VENUE_H3,
    spot_id: spotId,
    board: "production",
  };
}

/** A stable per-fixture UUID: `00000000-0000-4000-8000-0000000000NN`. */
function sessionId(n: number): string {
  return `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
}

export function buildFixture(index: number, input: ScenarioInput): Fixture {
  const id = sessionId(index);
  const spotId = input.spotId ?? null;
  const lastEnd = Math.max(...input.sets.map((s) => s.endedAtMs));

  const evidence: Evidence = {
    sessionId: id,
    movementConfigVersion: CONFIG_VERSION,
    clientVersion: "0.1.0+fixture",
    location: { lat: VENUE.lat, lng: VENUE.lng, accuracyM: 8, isMocked: false },
    spotId,
    sets: input.sets.map((s) => s.set),
  };

  return {
    about: input.about,
    evidence,
    session: sessionRow(id, SESSION_START_MS, spotId),
    submitAtMs: input.submitAtMs ?? SESSION_START_MS + lastEnd + 5000,
    context: {
      userId: USER_ID,
      unlocked: input.unlocked ?? UNLOCKED_AT_SIGNUP,
      alreadyEarnedToday: input.alreadyEarnedToday ?? 0,
    },
  };
}

// ---------------------------------------------------------------------------
// The ten scenarios
// ---------------------------------------------------------------------------

const squatClean = buildSet({
  movementId: SQUAT.id,
  measurementType: SQUAT.measurementType,
  restSignal: SQUAT.rest,
  // 20 reps, 1.72 s rising to 2.84 s. cycleCv 0.127 against a CV_HEALTHY of
  // 0.06, and a last-third/first-third ratio of 1.33 against a
  // FATIGUE_SLOPE_HEALTHY of 1.02 — both tempo penalties are exactly zero, with
  // enough margin to survive a Day-4 retune of either constant.
  reps: {
    count: 20,
    cycleMs: cycleFrom({ baseMs: 1900, driftMs: 40, weaveMs: 120 }),
    tempo: "healthy",
    gapMs: () => 600,
    peak: (i) => 82 + wobble(i, 2, 4),
    confMean: (i) => 0.88 + wobble(i, 3, 0.04),
  },
  trace: { kind: "consistent" },
});

const squatShallow = buildSet({
  movementId: SQUAT.id,
  measurementType: SQUAT.measurementType,
  restSignal: SQUAT.rest,
  // Every rep crosses enterPeak (110) — Track A counted it, so it exists — but
  // none gets near romTarget (80). romScore is the GRADE, not the gate.
  reps: {
    count: 12,
    cycleMs: cycleFrom({ baseMs: 1550, driftMs: 50, weaveMs: 130 }),
    tempo: "healthy",
    gapMs: () => 500,
    peak: (i) => 105 + wobble(i, 5, 3),
    confMean: (i) => 0.84 + wobble(i, 6, 0.05),
  },
  trace: { kind: "none" },
});

const squatMetronome = buildSet({
  movementId: SQUAT.id,
  measurementType: SQUAT.measurementType,
  restSignal: SQUAT.rest,
  // Eight identical 2 s cycles: cv is exactly 0, so uniformityPenalty is exactly
  // UNIFORMITY_MAX_PENALTY and tempoFactor is exactly 0.65. Eight reps is also
  // below MIN_REPS_FOR_FATIGUE (10), which is the point — a set this short has no
  // beginning and end to compare, so absence of drift must NOT be penalised.
  reps: {
    count: 8,
    cycleMs: () => 2000,
    tempo: "uniform",
    gapMs: () => 800,
    peak: () => 85,
    confMean: () => 0.91,
  },
  trace: { kind: "consistent" },
});

const squatImpossible = buildSet({
  movementId: SQUAT.id,
  measurementType: SQUAT.measurementType,
  restSignal: SQUAT.rest,
  // 500 ms cycles with 80 ms gaps. Median cycle is below IMPOSSIBLE_CYCLE_MS
  // (900), which forces tempoFactor to the 0.5 floor regardless of the other two
  // terms; every gap is below CADENCE_GAP_FLOOR_MS (400); and because the cadence
  // is uniform and undrifted, both tempo flags fire as well. No trace — 5 Hz
  // cannot resolve a 500 ms rep, which is itself part of the story.
  reps: {
    count: 20,
    cycleMs: () => 500,
    tempo: "impossible",
    gapMs: () => 80,
    peak: () => 84,
    confMean: () => 0.9,
  },
  trace: { kind: "none" },
});

const pullUpKip = buildSet({
  movementId: PULL_UP.id,
  measurementType: PULL_UP.measurementType,
  restSignal: PULL_UP.rest,
  // hipDriftNorm 0.45 is at KIP_FULL (0.40), so the dock saturates at
  // KIP_MAX_DOCK (0.35) on every rep. shoulderWristDyNorm stays under
  // PULLUP_DY_LIMIT (0.25), so the second signal CONFIRMS these — the kip and the
  // confirmation are independent penalties and this fixture isolates the first.
  reps: {
    count: 10,
    cycleMs: cycleFrom({ baseMs: 2400, driftMs: 80, weaveMs: 150 }),
    tempo: "healthy",
    gapMs: () => 900,
    peak: (i) => 62 + wobble(i, 8, 4),
    confMean: (i) => 0.86 + wobble(i, 9, 0.04),
    hipDriftNorm: (i) => 0.45 + wobble(i, 10, 0.02),
    shoulderWristDyNorm: () => 0.12,
  },
  trace: { kind: "consistent" },
});

const pullUpUnconfirmed = buildSet({
  movementId: PULL_UP.id,
  measurementType: PULL_UP.measurementType,
  restSignal: PULL_UP.rest,
  // shoulderWristDyNorm 0.32 exceeds PULLUP_DY_LIMIT: the wrist never collapsed
  // toward the shoulder line, so the chin probably never cleared the bar. The
  // primary signal (elbow angle) says the rep happened; the confirming signal
  // disagrees. Multiplicative 0.75, and no kip dock — hips are quiet.
  reps: {
    count: 8,
    cycleMs: cycleFrom({ baseMs: 2300, driftMs: 0, weaveMs: 240 }),
    tempo: "healthy",
    gapMs: () => 850,
    peak: (i) => 66 + wobble(i, 12, 4),
    confMean: (i) => 0.83 + wobble(i, 13, 0.04),
    hipDriftNorm: () => 0.05,
    shoulderWristDyNorm: (i) => 0.32 + wobble(i, 14, 0.03),
  },
  trace: { kind: "consistent" },
});

const plankSag = buildSet({
  movementId: PLANK.id,
  measurementType: PLANK.measurementType,
  restSignal: PLANK.rest,
  // 25 s in form, a 3 s sag where the trunk left the 160–185 band (accruing
  // stops upstream in Track A, so it is a GAP and not a segment), 32 s back in
  // form, then a 2 s micro-segment that is below MIN_HOLD_SEGMENT_MS (5000) and
  // earns nothing. Qualifying total 57 s across two segments, so the discount is
  // 1/1.1 — this is the fixture that settles api-contract.md:133 ("is 3 x 20 s
  // worth the same as 1 x 60 s?") with a number.
  holdSegments: [
    { tStartMs: 3500, tEndMs: 28500, meanSignal: 173, confMean: 0.88 },
    { tStartMs: 31500, tEndMs: 63500, meanSignal: 171, confMean: 0.84 },
    { tStartMs: 64500, tEndMs: 66500, meanSignal: 169, confMean: 0.79 },
  ],
  // A hold has no state machine, so crossCheckTrace returns zero flags for it —
  // there is nothing rep-shaped to compare. Emitting one anyway keeps the payload
  // realistic and proves that path stays quiet.
  trace: { kind: "none" },
});

const traceLie = buildSet({
  movementId: SQUAT.id,
  measurementType: SQUAT.measurementType,
  restSignal: SQUAT.rest,
  // The summary claims twelve deep squats. The trace shows seven bumps: three
  // DEEPER than claimed, four far too shallow, and five claimed windows with no
  // movement at all. Both per-rep trace assertions fire, in opposite directions:
  //   claimed shallower than the trace  -> TRACE_PEAK_INCONSISTENT. 5 Hz can miss
  //       a peak but can never invent a deeper one, so this is physically
  //       impossible rather than merely out of tolerance.
  //   claimed deeper than the trace     -> TRACE_PEAK_OUT_OF_TOLERANCE.
  // Only the three deep bumps cross enterPeak, so the crossing count is 3 against
  // 12 claimed reps — divergence 9, well past the ±1 tolerance.
  //
  // The score is computed from the summary anyway and is HIGH. That is I13: a
  // contradiction is recorded for a human, never acted on inline.
  reps: {
    count: 12,
    cycleMs: cycleFrom({ baseMs: 2000, driftMs: 55, weaveMs: 140 }),
    tempo: "healthy",
    gapMs: () => 650,
    peak: () => 82,
    confMean: () => 0.9,
  },
  trace: {
    kind: "custom",
    bumps: (reps) => [
      bumpAt(reps, 0, 70),
      bumpAt(reps, 1, 70),
      bumpAt(reps, 2, 70),
      bumpAt(reps, 4, 128),
      bumpAt(reps, 6, 128),
      bumpAt(reps, 8, 128),
      bumpAt(reps, 10, 128),
    ],
  },
});

const lockedPistolSquat = buildSet({
  movementId: PISTOL_SQUAT.id,
  measurementType: PISTOL_SQUAT.measurementType,
  restSignal: PISTOL_SQUAT.rest,
  // A textbook T4 set: deep, confident, well-paced. It scores ZERO, because the
  // account has never unlocked pistol squats. I10 is satisfied by scoring nothing
  // rather than by rejecting — the honest squat in set 0 still banks its points,
  // and MOVEMENT_NOT_UNLOCKED records what was forgone.
  //
  // Five reps is exactly MIN_REPS_FOR_VARIANCE, so this is the shortest set whose
  // cycleCv is computed at all — and the one that exposed why the spread here is
  // structural rather than hashed. See [TempoShape].
  reps: {
    count: 5,
    cycleMs: cycleFrom({ baseMs: 3200, driftMs: 60, weaveMs: 260 }),
    tempo: "healthy",
    gapMs: () => 1200,
    peak: (i) => 78 + wobble(i, 17, 3),
    confMean: (i) => 0.9 + wobble(i, 18, 0.03),
    // A minute after the first set ends — a real rest between sets, and what
    // makes this fixture exercise max(endedAtMs) ACROSS sets rather than within
    // one.
    firstStartMs: squatClean.endedAtMs + 60000,
  },
  trace: { kind: "none" },
});

const replayedClock = buildSet({
  movementId: SQUAT.id,
  measurementType: SQUAT.measurementType,
  restSignal: SQUAT.rest,
  // Shape-perfect evidence claiming three minutes of work. The session was opened
  // 40 s before it arrived, so the claimed timeline cannot have happened inside
  // the observed window. This is the replay attack I3 exists for, and the only
  // fixture here that fails a Class-1 gate: it is REJECTED with 400 and never
  // reaches the scorer, so its golden has no score at all.
  reps: {
    count: 60,
    cycleMs: cycleFrom({ baseMs: 2000, driftMs: 10, weaveMs: 150 }),
    tempo: "healthy",
    gapMs: () => 600,
    peak: (i) => 84 + wobble(i, 20, 4),
    confMean: (i) => 0.89 + wobble(i, 21, 0.04),
  },
  trace: { kind: "none" },
});

// ---------------------------------------------------------------------------

export interface NamedFixture {
  name: string;
  fixture: Fixture;
}

export const FIXTURES: readonly NamedFixture[] = [
  {
    name: "squat_20_clean",
    fixture: buildFixture(1, {
      about: "The happy path, and the only fixture that must produce ZERO flags. " +
        "Twenty deep squats (romScore ~0.9), high confidence, natural tempo " +
        "spread and fatigue drift, and a 5 Hz trace that agrees with every " +
        "claimed peak. tempoFactor 1.0, no cap, nothing to shadow-flag. If this " +
        "golden ever grows a flag, something upstream changed and every other " +
        "fixture's expectations need re-reading.",
      sets: [squatClean],
    }),
  },
  {
    name: "squat_shallow",
    fixture: buildFixture(2, {
      about: "ROM as a grade, not a gate. Twelve reps that all cross enterPeak (110) " +
        "so Track A legitimately counted them, but stop near 105 instead of " +
        "reaching romTarget (80) — romScore around 0.15 instead of 0.95. No " +
        "trace on the wire, which costs one info-severity TRACE_MISSING and " +
        "nothing else: an absent trace must never lower a score.",
      sets: [squatShallow],
    }),
  },
  {
    name: "squat_metronome",
    fixture: buildFixture(3, {
      about: "Bots are metronomes. Eight cycles of exactly 2000 ms give cycleCv 0, so " +
        "uniformityPenalty saturates at 0.35 and tempoFactor is exactly 0.65. " +
        "Eight reps is deliberately below MIN_REPS_FOR_FATIGUE (10): NO_FATIGUE_" +
        "DRIFT must NOT fire, because a set this short has no first and last " +
        "third to compare and absence of evidence is not evidence of a bot.",
      sets: [squatMetronome],
    }),
  },
  {
    name: "squat_impossible_cadence",
    fixture: buildFixture(4, {
      about: "Everything a machine-gunned replay trips at once, and the one fixture " +
        "whose flag list is meant to look alarming. 500 ms cycles put the median " +
        "under IMPOSSIBLE_CYCLE_MS (900) so tempoFactor is forced to the 0.5 " +
        "floor; the 80 ms gaps are all under CADENCE_GAP_FLOOR_MS (400); and " +
        "because the cadence is perfectly uniform and never slows, TEMPO_UNIFORM " +
        "and NO_FATIGUE_DRIFT fire too. Still scored, still not rejected — I13.",
      sets: [squatImpossible],
    }),
  },
  {
    name: "pullup_10_kip",
    fixture: buildFixture(5, {
      about: "B18 in isolation. Ten pull-ups with hipDriftNorm ~0.45, at KIP_FULL " +
        "(0.40), so every rep takes the maximum 0.35 dock — formFactor lands near " +
        "0.63 instead of 0.97. shoulderWristDyNorm is 0.12, under " +
        "PULLUP_DY_LIMIT (0.25), so the confirming signal AGREES and " +
        "PULLUP_UNCONFIRMED must not appear. Ten rep-scoped KIP_DETECTED flags " +
        "and nothing else.",
      sets: [pullUpKip],
    }),
  },
  {
    name: "pullup_unconfirmed",
    fixture: buildFixture(6, {
      about: "B16 in isolation. Eight pull-ups whose elbow angle says the rep happened " +
        "but whose shoulderWristDyNorm (~0.32) says the wrist never collapsed " +
        "toward the shoulder line, i.e. the chin probably never cleared the bar. " +
        "Each rep is multiplied by PULLUP_UNCONFIRMED_FACTOR (0.75) and flagged. " +
        "hipDriftNorm is 0.05, under KIP_FREE (0.15), so no kip dock — the two " +
        "penalties are independent and this fixture must not mix them.",
      sets: [pullUpUnconfirmed],
    }),
  },
  {
    name: "plank_60s_sag",
    fixture: buildFixture(7, {
      about: "The holdTime path, and the answer to api-contract.md:133. 25 s in form, " +
        "a 3 s sag where the trunk left the 160-185 band (Track A stops accruing, " +
        "so it is a gap, not a segment), 32 s back in form, then a 2 s " +
        "micro-segment below MIN_HOLD_SEGMENT_MS (5000) that earns nothing. Two " +
        "qualifying segments over 57 s: discount 1/1.1, bandScore 0.96, " +
        "repEquivalents ~17.27. ZERO flags — a hold has no state machine, so the " +
        "trace cross-check returns nothing, and there is no cadence to be robotic " +
        "about, so there is no tempo term either.",
      sets: [plankSag],
    }),
  },
  {
    name: "squat_trace_contradiction",
    fixture: buildFixture(8, {
      about: "Why the trace earns its bytes. The per-rep summary claims twelve deep " +
        "squats; the 5 Hz trace shows seven bumps, three DEEPER than claimed " +
        "(TRACE_PEAK_INCONSISTENT — 5 Hz can miss a peak but can never invent a " +
        "deeper one, so this is physically impossible), four far too shallow and " +
        "five windows with no movement at all (TRACE_PEAK_OUT_OF_TOLERANCE), and a " +
        "crossing count of 3 against 12 claimed reps (TRACE_REP_COUNT_DIVERGENT). " +
        "Thirteen contradiction-severity flags — and the score is computed from " +
        "the summary anyway and is HIGH. Nothing here rejects or discounts; a " +
        "human reads session_flags afterwards and calls void_session(). I13.",
      sets: [traceLie],
    }),
  },
  {
    name: "squat_plus_locked_pistol",
    fixture: buildFixture(9, {
      about: "I10, and per-set independence. Two sets in one session: an honest " +
        "unlocked squat, then a textbook pistol squat the account has never " +
        "earned. The pistol set is deep, confident and well-paced, and it scores " +
        "EXACTLY ZERO — not a rejection, not a discount, zero, with " +
        "MOVEMENT_NOT_UNLOCKED recording the forgone score. The squat set still " +
        "banks in full, so rawTotal is the squat alone. Also the only " +
        "multi-set fixture: it pins the wall-clock gate's max(endedAtMs) across " +
        "sets rather than within one.",
      sets: [squatClean, lockedPistolSquat],
    }),
  },
  {
    name: "squat_replay_bad_clock",
    fixture: buildFixture(10, {
      about: "The only Class-1 gate failure in the set. Shape-perfect evidence claiming " +
        "roughly three minutes of work, submitted 40 s after the session opened. " +
        "checkWallClock compares two DURATIONS — claimed span against the " +
        "server's own observed window — so no client clock is trusted and a " +
        "spoofed epoch cancels out (I3). Rejected with 400 " +
        "TIMELINE_OUT_OF_WINDOW before the scorer runs, before the session is " +
        "consumed, and before anything is written. The golden has no score.",
      sets: [replayedClock],
      submitAtMs: SESSION_START_MS + 40000,
    }),
  },
];

/** Looks a fixture up by name; throws rather than returning undefined. */
export function fixtureByName(name: string): Fixture {
  const found = FIXTURES.find((f) => f.name === name);
  if (!found) {
    throw new Error(`no fixture '${name}' — known: ${FIXTURES.map((f) => f.name).join(", ")}`);
  }
  return found.fixture;
}
