/// Writes `test/server/fixtures/*.json` and their `*.expected.json` goldens.
///
///     node test/server/tools/build_fixtures.ts          (no flags needed)
///     deno run --allow-read --allow-write test/server/tools/build_fixtures.ts
///
/// Runs under both because nothing it touches is Deno-only: the fixture specs,
/// the catalogue literal, the parser, the scorer and the validators are all pure.
/// `_shared/db.ts`, `_shared/h3.ts`, `_shared/repo.ts` and the three route
/// entrypoints are the Deno boundary and none of them are imported here.
///
/// WHAT IT DOES PER FIXTURE
///   1. Serialises `evidence` to JSON and parses it back through `parseEvidence`.
///      Not a formality — it proves the wire payload the client would send is one
///      the server accepts, which is a different claim from "this object
///      type-checks". A fixture that fails here would produce a golden for a
///      submission that could never arrive.
///   2. Runs `checkSubmitGates` against the fixture's session row and arrival
///      stamp, i.e. the Class-1 validation exactly as `session-submit` orders it.
///   3. Only if the gate passed: `assertResolvable`, `scoreEvidence`, and
///      `crossCheckTrace` per set — the route's steps 4, 5 and 7.
///   4. Checks the result against the fixture's declared INTENT (below) and refuses
///      to write if it fails.
///   5. Writes both files.
///
/// WHY STEP 4 EXISTS
/// A golden generated from the implementation can only ever agree with the
/// implementation, so `deno task fixtures && deno task test` always passes no
/// matter what the numbers became. The intent checks are the thing that stops
/// that: each one restates, as an assertion, the sentence in the fixture's
/// `about`. Tune `CV_HEALTHY` and `squat_metronome` stops producing exactly 0.65,
/// and this script fails instead of quietly rewriting a golden that no longer
/// means what it says.
///
/// Correctness against the contract is a third, separate thing, and lives in
/// `scoring_test.ts` — api-contract.md's worked examples asserted as literals.

// `node:` specifiers rather than `Deno.*`: both runtimes resolve them, so this
// script is not tied to the one that happens to be installed. The local TS server
// reports them as unresolved because neither Deno's type bundle nor `@types/node`
// is present on this machine — that is a tooling gap, not a broken import.
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";

import { parseEvidence } from "../../../supabase/functions/_shared/evidence/schema.ts";
import { assertResolvable } from "../../../supabase/functions/_shared/catalogue.ts";
import { scoreEvidence } from "../../../supabase/functions/_shared/scoring/score.ts";
import {
  crossCheckTrace,
  type TraceCheckResult,
} from "../../../supabase/functions/_shared/validation/trace.ts";
import { checkSubmitGates } from "../../../supabase/functions/_shared/validation/session.ts";
import { HttpError } from "../../../supabase/functions/_shared/responses.ts";
import { resolveThresholds } from "../../../supabase/functions/_shared/evidence/thresholds.ts";
import type { Flag } from "../../../supabase/functions/_shared/flags.ts";
import { type Fixture, FIXTURES } from "./fixtures.ts";
import { testCatalogue } from "./catalogue.ts";
import { type Golden, projectAccepted, projectRejected, serialise } from "./golden.ts";

const OUT_DIR = fileURLToPath(new URL("../fixtures/", import.meta.url));

/** Runs one fixture through the route's pipeline and projects the golden. */
export function evaluate(fixture: Fixture): Golden {
  // Step 1 — round-trip. `parseEvidence` is what the route calls on the raw body.
  const wire = JSON.parse(JSON.stringify(fixture.evidence));
  const evidence = parseEvidence(wire);

  const catalogue = testCatalogue();

  // Step 2 — Class 1. Non-mutating: the real route reads the session row before
  // the one-shot consume for exactly this reason.
  try {
    checkSubmitGates(fixture.session, evidence, fixture.context.userId, fixture.submitAtMs);
  } catch (failure) {
    if (failure instanceof HttpError) {
      return projectRejected(fixture, { code: failure.code, status: failure.status });
    }
    throw failure;
  }

  // Step 4 of the route — before the consume, so a bad payload cannot burn a
  // session (I2 makes the session non-retryable).
  assertResolvable(catalogue, evidence);

  // Step 5 — Class 2, which never rejects.
  const traceChecks: TraceCheckResult[] = evidence.sets.map((set, i) =>
    crossCheckTrace(
      set,
      i,
      resolveThresholds(catalogue, set.movementId, set.calibration.restSignal),
    )
  );
  const traceFlags: Flag[] = traceChecks.flatMap((c) => c.flags);

  // Step 7.
  const score = scoreEvidence(evidence, {
    catalogue,
    unlockedMovements: new Set(fixture.context.unlocked),
    alreadyEarnedToday: fixture.context.alreadyEarnedToday,
  });

  // Step 8's flag order, replicated: the route persists
  // `[...score.flags, ...traceFlags]`.
  return projectAccepted(fixture, score, [...score.flags, ...traceFlags], traceChecks);
}

// ---------------------------------------------------------------------------
// Intent checks — the `about` string of each fixture, as an assertion
// ---------------------------------------------------------------------------

type Intent = (g: Golden) => string | null;

function codes(g: Golden): string[] {
  return (g.score?.flags ?? []).map((f) => f.code);
}

function onlyCodes(g: Golden, expected: readonly string[]): string | null {
  const actual = codes(g);
  const same = actual.length === expected.length &&
    expected.every((c, i) => actual[i] === c);
  return same ? null : `expected flags [${expected.join(", ")}], got [${actual.join(", ")}]`;
}

/** Counts repetitions of one code, ignoring everything else. */
function countCode(g: Golden, code: string): number {
  return codes(g).filter((c) => c === code).length;
}

function accepted(g: Golden): string | null {
  if (g.gate !== null) return `expected the gates to pass, got ${g.gate.code}`;
  if (g.score === null) return "expected a score";
  return null;
}

const INTENT: Record<string, Intent> = {
  // The happy path. A flag here means something upstream moved.
  squat_20_clean: (g) => {
    const wrong = accepted(g) ?? onlyCodes(g, []);
    if (wrong) return wrong;
    const set = g.score!.sets[0];
    if (set.repCount !== 20) return `expected 20 reps, got ${set.repCount}`;
    if (set.tempoFactor !== 1) return `expected tempoFactor 1, got ${set.tempoFactor}`;
    if (!set.scored) return "expected the set to score";
    if (g.score!.awardedTotal <= 0) return "expected a positive awardedTotal";
    if (g.traceChecks[0].traceReps !== 20) {
      return `trace counted ${g.traceChecks[0].traceReps} reps, expected 20`;
    }
    return null;
  },

  // ROM is a grade, not a gate: the reps exist, they are just shallow.
  squat_shallow: (g) => {
    const wrong = accepted(g) ?? onlyCodes(g, ["TRACE_MISSING"]);
    if (wrong) return wrong;
    const set = g.score!.sets[0];
    if (set.repCount !== 12) return `expected 12 reps, got ${set.repCount}`;
    const deep = set.romScores.filter((r) => r >= 0.3).length;
    if (deep > 0) return `${deep} reps scored romScore >= 0.3 in a shallow fixture`;
    if (set.formFactor >= 0.9) return `formFactor ${set.formFactor} is not a shallow-squat grade`;
    return null;
  },

  // Uniformity alone. Eight reps is below MIN_REPS_FOR_FATIGUE, so the drift term
  // must be absent rather than merely zero — fatigueSlope null, not 1.
  squat_metronome: (g) => {
    const wrong = accepted(g) ?? onlyCodes(g, ["TEMPO_UNIFORM"]);
    if (wrong) return wrong;
    const set = g.score!.sets[0];
    if (set.tempo.cycleCv !== 0) return `expected cycleCv 0, got ${set.tempo.cycleCv}`;
    if (set.tempo.fatigueSlope !== null) {
      return `expected fatigueSlope null for an 8-rep set, got ${set.tempo.fatigueSlope}`;
    }
    if (set.tempoFactor !== 0.65) return `expected tempoFactor 0.65, got ${set.tempoFactor}`;
    return null;
  },

  // The whole suspicion stack at once, floored at 0.5.
  squat_impossible_cadence: (g) => {
    const wrong = accepted(g);
    if (wrong) return wrong;
    for (
      const code of [
        "IMPOSSIBLE_CADENCE",
        "CADENCE_FLOOR",
        "TEMPO_UNIFORM",
        "NO_FATIGUE_DRIFT",
        "TRACE_MISSING",
      ]
    ) {
      if (countCode(g, code) === 0) return `expected a ${code} flag`;
    }
    const set = g.score!.sets[0];
    if (set.tempoFactor !== 0.5) {
      return `expected tempoFactor floored at 0.5, got ${set.tempoFactor}`;
    }
    if (!set.tempo.impossibleCadence) return "expected impossibleCadence true";
    // Scored anyway. I13: suspicion is recorded, never acted on inline.
    if (g.score!.awardedTotal <= 0) return "I13 violated — a flagged set must still score";
    return null;
  },

  // B18 in isolation: the confirming signal must agree, so no PULLUP_UNCONFIRMED.
  pullup_10_kip: (g) => {
    const wrong = accepted(g) ?? onlyCodes(g, new Array(10).fill("KIP_DETECTED"));
    if (wrong) return wrong;
    const set = g.score!.sets[0];
    if (countCode(g, "PULLUP_UNCONFIRMED") > 0) {
      return "B16 must not fire in the B18 fixture — the two penalties are independent";
    }
    if (set.formFactor >= 0.9) return `expected a docked formFactor, got ${set.formFactor}`;
    return null;
  },

  // B16 in isolation: quiet hips, so no KIP_DETECTED.
  pullup_unconfirmed: (g) => {
    const wrong = accepted(g) ?? onlyCodes(g, new Array(8).fill("PULLUP_UNCONFIRMED"));
    if (wrong) return wrong;
    if (countCode(g, "KIP_DETECTED") > 0) {
      return "B18 must not fire in the B16 fixture — the two penalties are independent";
    }
    return null;
  },

  // The holdTime path, and the answer to "is 3 x 20 s worth 1 x 60 s?".
  plank_60s_sag: (g) => {
    const wrong = accepted(g) ?? onlyCodes(g, []);
    if (wrong) return wrong;
    const hold = g.score!.sets[0].hold;
    if (hold === null) return "expected a hold result";
    if (hold.segmentsTotal !== 3) return `expected 3 segments, got ${hold.segmentsTotal}`;
    if (hold.qualifyingSegments !== 2) {
      return `expected the 2 s micro-segment dropped, got ${hold.qualifyingSegments} qualifying`;
    }
    if (hold.qualifyingMs !== 57000) {
      return `expected 57000 ms qualifying, got ${hold.qualifyingMs}`;
    }
    if (hold.discount === 1) return "expected the two-segment discount to bite";
    if (g.score!.sets[0].tempoFactor !== 1) {
      return "a hold has no cadence, so tempoFactor must be a neutral 1";
    }
    return null;
  },

  // The trace earns its bytes — and I13 still pays out.
  squat_trace_contradiction: (g) => {
    const wrong = accepted(g);
    if (wrong) return wrong;
    for (
      const code of [
        "TRACE_PEAK_INCONSISTENT",
        "TRACE_PEAK_OUT_OF_TOLERANCE",
        "TRACE_REP_COUNT_DIVERGENT",
      ]
    ) {
      if (countCode(g, code) === 0) return `expected a ${code} flag`;
    }
    const contradictions = g.score!.flags.filter((f) => f.severity === "contradiction").length;
    if (contradictions < 3) return `expected >= 3 contradiction flags, got ${contradictions}`;
    if (g.traceChecks[0].traceReps === 12) {
      return "the trace must NOT agree with the claimed 12 reps";
    }
    // The load-bearing half: thirteen contradictions and the score is unchanged.
    const set = g.score!.sets[0];
    if (set.repCount !== 12) return `expected all 12 claimed reps scored, got ${set.repCount}`;
    if (g.score!.awardedTotal <= 0) {
      return "I13 violated — a contradiction must not zero the score inline";
    }
    return null;
  },

  // I10, and per-set independence within one session.
  squat_plus_locked_pistol: (g) => {
    const wrong = accepted(g);
    if (wrong) return wrong;
    if (g.score!.sets.length !== 2) return `expected 2 sets, got ${g.score!.sets.length}`;
    const [squat, pistol] = g.score!.sets;
    if (!squat.scored || squat.cappedScore <= 0) {
      return "the unlocked squat must still bank its points";
    }
    if (pistol.movementId !== "pistol_squat") return "set order changed";
    if (pistol.unlocked) return "pistol_squat must not be unlocked for this account";
    if (pistol.cappedScore !== 0) {
      return `expected a locked set to score 0, got ${pistol.cappedScore}`;
    }
    if (pistol.repScore <= 0) {
      return "forgoneScore must be non-zero, or the flag records nothing worth reading";
    }
    if (countCode(g, "MOVEMENT_NOT_UNLOCKED") !== 1) return "expected exactly one lock flag";
    if (g.score!.rawTotal !== squat.cappedScore) {
      return `rawTotal ${g.score!.rawTotal} must equal the unlocked set alone`;
    }
    return null;
  },

  // The only Class-1 rejection. Nothing downstream runs.
  squat_replay_bad_clock: (g) => {
    if (g.gate === null) return "expected the wall-clock gate to reject";
    if (g.gate.code !== "TIMELINE_OUT_OF_WINDOW") {
      return `expected TIMELINE_OUT_OF_WINDOW, got ${g.gate.code}`;
    }
    if (g.gate.status !== 400) return `expected status 400, got ${g.gate.status}`;
    if (g.score !== null) return "a rejected submission must not carry a score";
    return null;
  },
};

// ---------------------------------------------------------------------------

interface Outcome {
  name: string;
  golden: Golden;
  /** Null when the intent held. */
  problem: string | null;
}

/**
 * Runs every fixture through the pipeline and checks it against its declared
 * INTENT. Exported so `golden_test.ts` can assert the intents as part of the
 * suite — otherwise they only run when someone regenerates, and a regression
 * would sit unnoticed until the next person happened to touch a fixture.
 */
export function runIntents(): Outcome[] {
  return FIXTURES.map(({ name, fixture }) => {
    const golden = evaluate(fixture);
    const intent = INTENT[name];
    if (!intent) throw new Error(`fixture '${name}' has no intent check — add one`);
    return { name, golden, problem: intent(golden) };
  });
}

function summarise(o: Outcome): string {
  const g = o.golden;
  if (g.gate !== null) return `GATE ${g.gate.status} ${g.gate.code}`;
  const flags = g.score!.flags;
  const parts = [
    `${
      g.score!.sets.map((s) => `${s.movementId}:${s.repCount || `${s.holdMs / 1000}s`}`).join("+")
    }`,
    `awarded ${g.score!.awardedTotal}`,
    `xp ${g.score!.xp}`,
    flags.length === 0
      ? "no flags"
      : `${flags.length} flag(s) ${[...new Set(flags.map((f) => f.code))].join(",")}`,
  ];
  return parts.join("  |  ");
}

/**
 * True when this file is the entrypoint rather than something being imported.
 *
 * WHY THIS GUARD IS LOAD-BEARING
 * `golden_test.ts` imports [evaluate] from here. Without the guard, importing
 * this module rewrote all twenty fixture and golden files on the way past — so
 * the test regenerated each golden and then compared it against the file it had
 * just written, and passed no matter what the engine did. A regression lock that
 * re-locks itself on every run is not a lock.
 *
 * Both runtimes are checked because this file is run by `deno task fixtures` and
 * imported by the test suite under plain Node. Deno sets `import.meta.main`;
 * Node does not, so it falls back to comparing the resolved module URL against
 * the entrypoint.
 */
function isMainModule(): boolean {
  const meta = import.meta as { main?: boolean; url: string };
  if (meta.main !== undefined) return meta.main;
  const argv1 = (globalThis as { process?: { argv?: string[] } }).process?.argv?.[1];
  if (argv1 === undefined) return false;
  return meta.url === pathToFileURL(argv1).href;
}

function writeAll(): void {
  const outcomes = runIntents();
  const failures = outcomes.filter((o) => o.problem !== null);

  if (failures.length > 0) {
    const lines = failures.map((f) => `  ${f.name}\n    ${f.problem}\n`).join("");
    // Thrown rather than `process.exitCode = 1`: a non-zero exit is the only thing
    // that stops a CI run, and throwing gets it in both runtimes without reaching
    // for a Node global that Deno only provides through its compat layer.
    throw new Error(
      `\nRefusing to write goldens — ${failures.length} intent check(s) failed:\n\n${lines}\n` +
        "A golden is a regression lock, not a rubber stamp. Either the implementation\n" +
        "moved and the fixture's `about` no longer describes it, or the fixture needs\n" +
        "re-tuning. Fix the cause; do not weaken the check.",
    );
  }

  mkdirSync(OUT_DIR, { recursive: true });
  for (const { name, golden } of outcomes) {
    const fixture = FIXTURES.find((f) => f.name === name)!;
    writeFileSync(`${OUT_DIR}${name}.json`, serialise(fixture.fixture), "utf8");
    writeFileSync(`${OUT_DIR}${name}.expected.json`, serialise(golden), "utf8");
  }

  console.log(`\nWrote ${outcomes.length} fixtures + goldens to ${OUT_DIR}\n`);
  for (const o of outcomes) console.log(`  ${o.name.padEnd(28)} ${summarise(o)}`);
  console.log();
}

if (isMainModule()) writeAll();
