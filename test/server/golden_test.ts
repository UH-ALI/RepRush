/// The golden lock — every `.expected.json` re-derived and compared.
///
/// WHAT THIS FILE PROVES AND WHAT IT DOES NOT
/// It proves the scoring pipeline has not changed since the goldens were written.
/// It does NOT prove the pipeline is right: the goldens came out of the
/// implementation, so comparing the implementation against them is circular on
/// its own. Correctness is anchored separately in `scoring_test.ts`, which
/// asserts the worked examples from api-contract.md and requirements.md as
/// literals, and in `build_fixtures.ts`, whose INTENT checks refuse to write a
/// golden that contradicts the sentence in the fixture's own `about`.
///
/// Three layers, each catching what the others cannot:
///   scoring_test.ts   the numbers match the documents
///   build_fixtures.ts the goldens match what each fixture says it demonstrates
///   golden_test.ts    nothing has drifted since
///
/// The invariants near the bottom are the part that is NOT circular. They re-derive
/// the RepScore formula from each golden's own published fields, so a golden whose
/// `formFactor` and `tempoFactor` no longer multiply to its `repScore` fails even
/// if both files were regenerated together.

// `node:` specifiers rather than `Deno.*`, so this file loads under whichever
// runtime is installed. The local TS server reports them as unresolved because
// neither Deno's type bundle nor `@types/node` is present on this machine — a
// tooling gap, not a broken import, and the same one catalogue_test.ts and
// build_fixtures.ts carry. `onDisk` is annotated rather than inferred because
// with the module untyped `readdirSync` returns `any`, which would propagate an
// implicit `any` into every callback below.
import { readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { evaluate, runIntents } from "./tools/build_fixtures.ts";
import { FIXTURES } from "./tools/fixtures.ts";
import { type Golden, serialise } from "./tools/golden.ts";
import { PER_SET_CAP } from "../../supabase/functions/_shared/scoring/caps.ts";
import { round } from "../../supabase/functions/_shared/scoring/score.ts";
import { MOVEMENT_NOT_UNLOCKED, TRACE_MISSING } from "../../supabase/functions/_shared/flags.ts";
import { deepStrictEqual, near, ok, strictEqual, test } from "./_harness.ts";

const DIR = fileURLToPath(new URL("./fixtures/", import.meta.url));

const onDisk: string[] = readdirSync(DIR) as string[];
const goldenNames = onDisk.filter((f) => f.endsWith(".expected.json")).map((f) =>
  f.slice(0, -".expected.json".length)
);
const fixtureNames = onDisk.filter((f) => f.endsWith(".json") && !f.endsWith(".expected.json")).map(
  (f) => f.slice(0, -".json".length),
);

function readGolden(name: string): { text: string; parsed: Golden } {
  const text = readFileSync(`${DIR}${name}.expected.json`, "utf8");
  return { text, parsed: JSON.parse(text) as Golden };
}

/** `evaluate` per fixture, computed once and shared by every test below. */
const evaluated = new Map(FIXTURES.map(({ name, fixture }) => [name, evaluate(fixture)] as const));
const goldens = new Map(FIXTURES.map(({ name }) => [name, readGolden(name)] as const));
const NAMES = FIXTURES.map(({ name }) => name);

// ---------------------------------------------------------------------------
// The suite covers the whole directory
// ---------------------------------------------------------------------------

test("golden · every fixture has a golden and every golden has a fixture", () => {
  // Guards both directions of drift. A fixture with no golden is silently
  // untested; a golden with no fixture is a stale file that keeps passing because
  // nothing reads it.
  deepStrictEqual([...NAMES].sort(), [...goldenNames].sort(), "FIXTURES vs *.expected.json");
  deepStrictEqual([...NAMES].sort(), [...fixtureNames].sort(), "FIXTURES vs *.json");
  ok(NAMES.length >= 10, `expected at least the ten authored fixtures, found ${NAMES.length}`);
});

// ---------------------------------------------------------------------------
// The lock itself
// ---------------------------------------------------------------------------

for (const { name } of FIXTURES) {
  test(`golden · ${name} reproduces its .expected.json exactly`, () => {
    deepStrictEqual(
      evaluated.get(name),
      goldens.get(name)!.parsed,
      `${name}: re-run ` +
        "`node test/server/tools/build_fixtures.ts` only after reading golden.ts — " +
        "a regenerated golden proves nothing on its own",
    );
  });

  test(`golden · ${name} is byte-identical on disk`, () => {
    // Parsed comparison would pass even if the file were reformatted, and the
    // two-space indent with one number per line is the entire reason a golden
    // diff is readable. This is what fails when someone's editor reflows the JSON.
    strictEqual(
      goldens.get(name)!.text,
      serialise(evaluated.get(name)),
      `${name}: the file on disk is not what serialise() would write`,
    );
  });

  test(`golden · ${name} is deterministic`, () => {
    // scoreEvidence is pure — no clock, no randomness, no I/O. A difference here
    // means something downstream started reading `Date.now()` or a module-level
    // mutable, which would make every golden unstable and the ledger unreproducible.
    deepStrictEqual(evaluate(FIXTURES.find((f) => f.name === name)!.fixture), evaluated.get(name));
  });

  test(`golden · ${name} contains no negative zero`, () => {
    // THE `-0` REGRESSION. `romScore` divides by a negative denominator for every
    // decreasing movement, so a rep whose peakExtreme sits exactly on enterPeak
    // computes `0 / -30` = `-0`. `clamp` used to pass it through because
    // `-0 < 0` is false, and JSON round-trips `-0` as `+0` — which makes the
    // comparison above fail on two values that print identically, with no clue in
    // the diff about why. `clamp` now normalises it; this test names the cause if
    // that ever regresses on a path that does not go through `clamp`.
    deepStrictEqual(findNegativeZero(evaluated.get(name), name), []);
  });
}

function findNegativeZero(value: unknown, path: string): string[] {
  if (typeof value === "number") return Object.is(value, -0) ? [path] : [];
  if (Array.isArray(value)) {
    return value.flatMap((v, i) => findNegativeZero(v, `${path}/${i}`));
  }
  if (value !== null && typeof value === "object") {
    return Object.entries(value as Record<string, unknown>).flatMap(([k, v]) =>
      findNegativeZero(v, `${path}/${k}`)
    );
  }
  return [];
}

// ---------------------------------------------------------------------------
// Invariants across every golden — the part that is not circular
// ---------------------------------------------------------------------------

function accepted(): { name: string; golden: Golden }[] {
  return NAMES.map((name) => ({ name, golden: goldens.get(name)!.parsed }))
    .filter((g) => g.golden.gate === null);
}

test("golden · gate and score are mutually exclusive in every file", () => {
  // A rejected submission is never scored, and an accepted one always is. A file
  // with both would mean the route wrote a ledger row for a session it had
  // already refused.
  for (const name of NAMES) {
    const g = goldens.get(name)!.parsed;
    ok(
      (g.gate === null) !== (g.score === null),
      `${name}: gate ${JSON.stringify(g.gate)} with score ${g.score === null ? "null" : "present"}`,
    );
  }
});

test("golden · every set's repScore re-multiplies from its own published factors", () => {
  //     RepScore = reps × difficulty × formFactor × tempoFactor
  //     holdTime:  RepScore = (seconds / 3) × discount × difficulty × formFactor
  //
  // Computed here from the GOLDEN's fields, not from the engine, so this survives
  // both files being regenerated together. Each field is rounded to 6 dp on the
  // way out, hence a small tolerance rather than exact equality.
  for (const { name, golden } of accepted()) {
    for (const s of golden.score!.sets) {
      const expected = s.hold === null
        ? s.repCount * s.difficulty * s.formFactor * s.tempoFactor
        : s.hold.repEquivalents * s.difficulty * s.formFactor;
      near(
        s.repScore,
        expected,
        1e-3,
        `${name} set ${s.setIndex} (${s.movementId}): ` +
          `repScore does not equal its own factors multiplied back together`,
      );
    }
  }
});

test("golden · holds carry repEquivalents and no tempo penalty", () => {
  // The contract's hold formula has no tempoFactor: there is no cadence to be
  // robotic about. `scoreHoldSet` builds a synthetic TempoStats from an empty rep
  // list, which is fully neutral — asserting that here is what stops someone
  // "tidying up" the hold path into running tempo over hold segments.
  for (const { name, golden } of accepted()) {
    for (const s of golden.score!.sets) {
      if (s.measurementType !== "holdTime") continue;
      ok(s.hold !== null, `${name}: a holdTime set with no hold result`);
      strictEqual(s.repCount, 0, `${name}: a holdTime set must not report reps`);
      strictEqual(s.tempo.tempoFactor, 1, `${name}: a hold must not be tempo-penalised`);
      strictEqual(s.tempo.cycleCv, null);
      strictEqual(s.tempo.fatigueSlope, null);
      strictEqual(s.formFactor, s.hold!.formFactor, `${name}: the set's formFactor is the hold's`);
      ok(s.holdMs > 0, `${name}: a scored hold should have qualifying time`);
    }
  }
});

test("golden · rep sets carry no hold result", () => {
  for (const { name, golden } of accepted()) {
    for (const s of golden.score!.sets) {
      if (s.measurementType === "holdTime") continue;
      strictEqual(s.hold, null, `${name}: a repBodyweight set produced a hold result`);
      strictEqual(s.holdMs, 0);
    }
  }
});

test("golden · cappedScore is the per-set cap and tier gating applied, and nothing else", () => {
  for (const { name, golden } of accepted()) {
    for (const s of golden.score!.sets) {
      const expected = s.unlocked ? Math.min(s.repScore, PER_SET_CAP) : 0;
      near(s.cappedScore, expected, 1e-3, `${name} set ${s.setIndex}: wrong cappedScore`);
      ok(s.cappedScore <= s.repScore + 1e-9, `${name}: capping increased the score`);
      ok(s.cappedScore <= PER_SET_CAP + 1e-9, `${name}: a set exceeded PER_SET_CAP`);
      strictEqual(s.scored, s.unlocked && s.cappedScore > 0, `${name}: wrong 'scored'`);
    }
  }
});

test("golden · a locked movement scores zero and says so", () => {
  // I10 without I13's hard lockout: the set scores nothing rather than the
  // submission being refused, so the athlete's other sets still land.
  const locked = NAMES.flatMap((name) => {
    const g = goldens.get(name)!.parsed;
    return g.score?.sets.filter((s) => !s.unlocked).map((s) => ({ name, s })) ?? [];
  });
  ok(locked.length > 0, "no fixture exercises a locked movement — the tier gate is untested");
  for (const { name, s } of locked) {
    strictEqual(s.cappedScore, 0, `${name}: a locked set awarded points`);
    ok(s.repScore > 0, `${name}: a locked set should still show what it was worth`);
    const g = goldens.get(name)!.parsed;
    ok(
      g.score!.flags.some(
        (f) =>
          f.code === MOVEMENT_NOT_UNLOCKED && f.setIndex === s.setIndex && f.severity === "warn",
      ),
      `${name}: a locked set with no MOVEMENT_NOT_UNLOCKED flag`,
    );
  }
});

test("golden · totals are the sum of capped sets, and XP is the awarded total rounded", () => {
  for (const { name, golden } of accepted()) {
    const score = golden.score!;
    const sum = score.sets.reduce((acc, s) => acc + s.cappedScore, 0);
    // rawTotal is the sum BEFORE the daily marginal cap, so it can only differ
    // from the sum of the published cappedScores by rounding.
    near(score.rawTotal, round(sum), 1e-3, `${name}: rawTotal is not the sum of its sets`);
    ok(
      score.awardedTotal <= score.rawTotal + 1e-9,
      `${name}: the daily cap increased the award (${score.awardedTotal} > ${score.rawTotal})`,
    );
    strictEqual(score.xp, Math.round(score.awardedTotal), `${name}: xp is not round(awardedTotal)`);
    // No fixture pushes a day's earnings past 600, so the marginal cap must not
    // have bitten — if one is added later this assertion should be replaced, not
    // quietly deleted.
    near(score.awardedTotal, score.rawTotal, 1e-3, `${name}: awarded differs from raw`);
  }
});

test("golden · one trace check per set, in order", () => {
  for (const { name, golden } of accepted()) {
    strictEqual(
      golden.traceChecks.length,
      golden.score!.sets.length,
      `${name}: traceChecks and sets disagree in length`,
    );
    golden.traceChecks.forEach((c, i) => strictEqual(c.setIndex, i, `${name}: traceChecks[${i}]`));
  }
  // A rejected submission is never scored, so it never reaches the trace check.
  for (const name of NAMES) {
    const g = goldens.get(name)!.parsed;
    if (g.gate !== null) {
      deepStrictEqual(g.traceChecks, [], `${name}: a rejected submission has trace checks`);
    }
  }
});

test("golden · every flag carries a severity and a scope that makes sense", () => {
  for (const { name, golden } of accepted()) {
    for (const f of golden.score!.flags) {
      ok(["info", "warn", "contradiction"].includes(f.severity), `${name}: severity ${f.severity}`);
      // Session-scoped flags carry null; set-scoped ones carry an index that
      // exists. A flag pointing at a set that is not in the payload cannot be
      // acted on by whoever reviews session_flags.
      if (f.setIndex !== null) {
        ok(
          f.setIndex >= 0 && f.setIndex < golden.score!.sets.length,
          `${name}: ${f.code} points at set ${f.setIndex} of ${golden.score!.sets.length}`,
        );
        if (f.repIndex !== null) {
          const s = golden.score!.sets[f.setIndex];
          ok(
            f.repIndex >= 0 && f.repIndex < s.repCount,
            `${name}: ${f.code} points at rep ${f.repIndex} of ${s.repCount}`,
          );
        }
      } else {
        strictEqual(f.repIndex, null, `${name}: ${f.code} has a repIndex but no setIndex`);
      }
    }
  }
});

// ---------------------------------------------------------------------------
// Named anchors — specific numbers worth pinning by hand
// ---------------------------------------------------------------------------

test("golden · squat_metronome is exactly 8 × 1.0 × 0.96 × 0.65", () => {
  // Workable on a calculator, which is the point: the uniformity penalty saturates
  // at 0.35 because cycleCv is exactly 0, so tempoFactor is exactly 0.65, and the
  // romScore of every rep is (85 − 110) / (80 − 110) = 0.833333.
  const g = goldens.get("squat_metronome")!.parsed;
  const s = g.score!.sets[0];
  strictEqual(s.repCount, 8);
  strictEqual(s.difficulty, 1);
  strictEqual(s.tempo.cycleCv, 0);
  strictEqual(s.tempo.uniformityPenalty, 0.35);
  strictEqual(s.tempo.fatiguePenalty, 0);
  strictEqual(s.tempo.impossibleCadence, false);
  strictEqual(s.tempo.fatigueSlope, null, "8 reps is below MIN_REPS_FOR_FATIGUE, so no slope");
  strictEqual(s.tempoFactor, 0.65);
  strictEqual(s.formFactor, 0.96);
  ok(s.romScores.every((r) => r === 0.833333), `romScores: ${s.romScores.join(", ")}`);
  strictEqual(g.score!.awardedTotal, 4.992);
  strictEqual(g.score!.xp, 5);
  deepStrictEqual(
    g.score!.flags.map((f) => [f.code, f.severity, f.setIndex, f.repIndex]),
    [["TEMPO_UNIFORM", "warn", 0, null]],
  );
});

test("golden · squat_20_clean is the only rep fixture with zero flags", () => {
  // Its `about` says so explicitly: "If this golden ever grows a flag, something
  // upstream changed and every other fixture's expectations need re-reading."
  const g = goldens.get("squat_20_clean")!.parsed;
  deepStrictEqual(g.score!.flags, []);
  strictEqual(g.score!.sets[0].repCount, 20);
  strictEqual(g.score!.sets[0].tempoFactor, 1, "a healthy tempo is unpenalised");
  strictEqual(g.traceChecks[0].traceReps, 20, "the trace agrees with the rep list");
  strictEqual(g.traceChecks[0].repsInsufficient, 0);

  // Scoped to repBodyweight, because `plank_60s_sag` is also flag-free and that
  // is correct rather than a duplicate: holds bail out of crossCheckTrace BEFORE
  // the missing-trace check, so an honest plank carries no TRACE_MISSING. It is
  // the visible consequence of the ordering that trace_test.ts pins directly.
  for (const { name, golden } of accepted()) {
    if (golden.score!.sets.every((s) => s.measurementType === "holdTime")) continue;
    if (name === "squat_20_clean") continue;
    ok(
      golden.score!.flags.length > 0,
      `${name} is also flag-free — either it duplicates the clean fixture or a check stopped firing`,
    );
  }
});

test("golden · squat_replay_bad_clock is rejected at the gate and never scored", () => {
  // I3. The fixture carries absolute epoch timestamps in its set offsets, so the
  // claimed span is decades wider than the observed window.
  const g = goldens.get("squat_replay_bad_clock")!.parsed;
  deepStrictEqual(g.gate, { code: "TIMELINE_OUT_OF_WINDOW", status: 400 });
  strictEqual(g.score, null);
});

test("golden · a traceless rep set carries exactly one TRACE_MISSING and scores normally", () => {
  // Track A does not emit a contract-shaped trace yet, so this is the shape every
  // real submission has today. `info`, never a rejection, and never a score
  // reduction — otherwise the backend could not ship before Seam 1 closes.
  for (const name of ["squat_shallow", "squat_impossible_cadence", "squat_plus_locked_pistol"]) {
    const g = goldens.get(name)!.parsed;
    const missing = g.score!.flags.filter((f) => f.code === TRACE_MISSING);
    strictEqual(missing.length, 1, `${name}: expected one TRACE_MISSING`);
    strictEqual(missing[0].severity, "info", `${name}: TRACE_MISSING is not info`);
    ok(g.score!.awardedTotal > 0, `${name}: an absent trace must not zero the score`);

    // The flag must point at the set that actually had no trace. Asserting
    // `traceChecks[0]` instead would be wrong for squat_plus_locked_pistol, whose
    // first set is the squat WITH a trace and whose second is the traceless
    // pistol — a hardcoded index passes for two fixtures and misdescribes the
    // third, which is the failure mode this whole file exists to prevent.
    const at = missing[0].setIndex;
    ok(at !== null, `${name}: TRACE_MISSING must be set-scoped`);
    strictEqual(
      g.traceChecks[at!].traceReps,
      null,
      `${name}: TRACE_MISSING points at a set that counted ${g.traceChecks[at!].traceReps} reps`,
    );
    // And every set that DID have a trace counted something.
    g.traceChecks.forEach((c, i) => {
      if (i === at) return;
      ok(c.traceReps !== null, `${name}: set ${i} has no trace and no TRACE_MISSING flag`);
    });
  }
});

test("golden · squat_trace_contradiction is the contradiction showcase", () => {
  // The one fixture whose trace deliberately disagrees with its rep list, and it
  // disagrees on EVERY rep — twelve reps, twelve peak contradictions, split
  // between the two peak assertions, plus one set-scoped count divergence.
  // Thirteen flags in total, all of them `contradiction`: the class that earns the
  // ledger its reversibility (I12).
  const g = goldens.get("squat_trace_contradiction")!.parsed;
  const repCount = g.score!.sets[0].repCount;
  strictEqual(repCount, 12);

  const contradictions = g.score!.flags.filter((f) => f.severity === "contradiction");
  strictEqual(contradictions.length, g.score!.flags.length, "every flag here is a contradiction");
  strictEqual(contradictions.length, repCount + 1, "one per rep plus one for the set");

  const count = (code: string) => contradictions.filter((f) => f.code === code).length;
  strictEqual(count("TRACE_PEAK_INCONSISTENT"), 3);
  strictEqual(count("TRACE_PEAK_OUT_OF_TOLERANCE"), 9);
  strictEqual(count("TRACE_REP_COUNT_DIVERGENT"), 1);

  // The two peak assertions are mutually exclusive per rep (`else if` in
  // crossCheckTrace), so together they account for every rep exactly once. That
  // is what makes the split above meaningful rather than incidental.
  strictEqual(
    count("TRACE_PEAK_INCONSISTENT") + count("TRACE_PEAK_OUT_OF_TOLERANCE"),
    repCount,
    "each rep must be contradicted exactly once",
  );
  // Rep-scoped findings name the rep; the set-scoped one does not.
  deepStrictEqual(
    contradictions.filter((f) => f.code !== "TRACE_REP_COUNT_DIVERGENT").map((f) => f.repIndex)
      .sort((a, b) => a! - b!),
    Array.from({ length: repCount }, (_, i) => i),
  );
  strictEqual(
    contradictions.find((f) => f.code === "TRACE_REP_COUNT_DIVERGENT")!.repIndex,
    null,
  );

  // And it still scores: I13's whole point is that a contradiction found on demo
  // day must never lock a judge out mid-take. Correction is retroactive.
  ok(g.score!.awardedTotal > 0, "a contradicted set is scored and flagged, not refused");
});

test("golden · every fixture still satisfies the intent declared in its `about`", () => {
  // Layer two of the three described at the top of this file. These checks live in
  // build_fixtures.ts and used to run only when someone regenerated the goldens,
  // which meant a regression could sit unnoticed until the next person happened to
  // touch a fixture. Running them here makes them part of every suite run.
  const problems = runIntents()
    .filter((o) => o.problem !== null)
    .map((o) => `${o.name}: ${o.problem}`);
  deepStrictEqual(
    problems,
    [],
    "a fixture no longer demonstrates what its `about` says it does — fix the cause, " +
      "do not regenerate the golden",
  );
});

test("golden · every movement named in a golden exists in the catalogue tier it claims", () => {
  // A golden is committed to the repo and read by whoever picks up Track B next.
  // A set claiming tier 4 for a tier 2 movement would be a stale transcription of
  // 0002 that catalogue_test.ts cannot see, because it only compares the literal
  // against the migration and not against these files.
  const seen = new Map<string, number>();
  for (const { golden } of accepted()) {
    for (const s of golden.score!.sets) {
      const prior = seen.get(s.movementId);
      ok(
        prior === undefined || prior === s.tier,
        `${s.movementId} appears at tier ${prior} and tier ${s.tier}`,
      );
      seen.set(s.movementId, s.tier);
    }
  }
  ok(seen.size >= 3, `the goldens only exercise ${seen.size} movements`);
});

// ---------------------------------------------------------------------------
// Shape
// ---------------------------------------------------------------------------

test("golden · the projection publishes every field the ledger needs", () => {
  // A field dropped from `GoldenSet` silently disappears from ten files and the
  // comparison still passes, because both sides go through the same projector.
  // Enumerating the keys here is what makes that a failure.
  const expectedKeys = [
    "setIndex",
    "movementId",
    "measurementType",
    "tier",
    "difficulty",
    "unlocked",
    "repCount",
    "holdMs",
    "formFactor",
    "tempoFactor",
    "repScore",
    "cappedScore",
    "scored",
    "romScores",
    "repFormFactors",
    "tempo",
    "hold",
  ].sort();
  for (const { name, golden } of accepted()) {
    for (const s of golden.score!.sets) {
      deepStrictEqual(Object.keys(s).sort(), expectedKeys, `${name} set ${s.setIndex}`);
    }
    deepStrictEqual(
      Object.keys(golden).sort(),
      ["about", "gate", "score", "traceChecks"].sort(),
      `${name}: top-level golden keys`,
    );
  }
});

test("golden · per-rep arrays are positional with the evidence's reps", () => {
  // A regression in one rep of twenty is invisible in the set-level mean, which is
  // why these are flat arrays at all — and why their length has to match the rep
  // count exactly rather than merely being "about right".
  for (const { name, golden } of accepted()) {
    for (const s of golden.score!.sets) {
      strictEqual(s.romScores.length, s.repCount, `${name} set ${s.setIndex}: romScores`);
      strictEqual(s.repFormFactors.length, s.repCount, `${name} set ${s.setIndex}: repFormFactors`);
      for (const v of s.romScores) {
        ok(v >= 0 && v <= 1, `${name}: romScore ${v} outside [0, 1]`);
      }
      // formFactor per rep is NOT bounded below by FORM_FLOOR: the kip dock and the
      // pull-up confirmation penalty apply after the floor, deliberately, so a
      // badly-kipped rep can fall under 0.60. Asserting the floor here would
      // re-introduce the bug that made B18 free for exactly the shallow reps it
      // exists to punish.
      for (const v of s.repFormFactors) {
        ok(v > 0 && v <= 1, `${name}: rep formFactor ${v} outside (0, 1]`);
      }
    }
  }
});

test("golden · about is carried into the file so a golden is self-describing", () => {
  // Read in isolation — which is how a reviewer sees it in a diff — a golden with
  // no prose is just a wall of numbers.
  for (const { name, fixture } of FIXTURES) {
    const g = goldens.get(name)!.parsed;
    strictEqual(g.about, fixture.about, `${name}: the golden's about drifted from the fixture's`);
    ok(g.about.length > 80, `${name}: the about is too short to explain anything`);
  }
});
