/// Threshold resolution — `threshold = calibration.restSignal + offset`.
///
/// The offsets asserted here are the table in docs/api-contract.md §Movement
/// configs, transcribed into `supabase/migrations/0003_config_versions.sql` and
/// again into `tools/catalogue.ts`. `catalogue_test.ts` pins the transcription to
/// the SQL; this file pins the arithmetic that turns it into an absolute number.
///
/// WHY THIS DESERVES ITS OWN FILE
/// Every other number in the system is downstream of these three. A sign error in
/// `enterPeakOffset` does not look like a bug in threshold resolution — it looks
/// like every athlete in the demo suddenly having terrible form, or a rep counter
/// that never fires. Isolating the resolution step means that failure is a red
/// test with a line number instead of a mystery on Day 6.

import {
  atLeastAsExtreme,
  type Catalogue,
  CatalogueError,
  isDecreasing,
  moreExtreme,
  resolveThresholds,
  toleranceFor,
  TRACE_TOLERANCE_DEG,
  TRACE_TOLERANCE_RATIO,
} from "../../supabase/functions/_shared/evidence/thresholds.ts";
import { assertResolvable, buildCatalogue } from "../../supabase/functions/_shared/catalogue.ts";
import { testCatalogue } from "./tools/catalogue.ts";
import { CONFIG_VERSION, PLANK, PULL_UP, SQUAT } from "./tools/fixtures.ts";
import { near, ok, strictEqual, test, throwsCode } from "./_harness.ts";

const catalogue = testCatalogue();

test("resolveThresholds · api-contract.md §Movement configs — squat at rest 175", () => {
  const t = resolveThresholds(catalogue, "squat", 175);
  // Offsets −65 / −25 / −95 against the athlete's own rest pose.
  strictEqual(t.enterPeak, 110);
  strictEqual(t.enterRest, 150);
  strictEqual(t.romTarget, 80);
  strictEqual(t.unit, "deg");
  strictEqual(t.direction, "decreasing");
  strictEqual(t.tolerance, TRACE_TOLERANCE_DEG);
  strictEqual(t.holdBand, null);
  // And these are exactly the numbers the contract's ROM table computes with.
  strictEqual(t.enterPeak, SQUAT.enterPeak);
  strictEqual(t.enterRest, SQUAT.enterRest);
  strictEqual(t.romTarget, SQUAT.romTarget);
});

test("resolveThresholds · api-contract.md §Movement configs — pull-up at rest 175", () => {
  const t = resolveThresholds(catalogue, "pull_up", 175);
  // Offsets −85 / −25 / −120. The contract's worked example divides by (55−90).
  strictEqual(t.enterPeak, 90);
  strictEqual(t.enterRest, 150);
  strictEqual(t.romTarget, 55);
  strictEqual(t.enterPeak, PULL_UP.enterPeak);
  strictEqual(t.romTarget, PULL_UP.romTarget);
});

test("resolveThresholds · the hysteresis band is ordered correctly for a decreasing signal", () => {
  // enterPeak must be MORE extreme than enterRest, or the state machine latches
  // on the way down and never releases: one rep counted, then silence.
  const t = resolveThresholds(catalogue, "squat", 175);
  ok(t.enterPeak < t.enterRest, `enterPeak ${t.enterPeak} must be below enterRest ${t.enterRest}`);
  ok(t.romTarget < t.enterPeak, `romTarget ${t.romTarget} must be deeper than the gate`);
  // Same for every decreasing movement in the catalogue, at any rest pose.
  for (const id of catalogue.offsets.keys()) {
    const resolved = resolveThresholds(catalogue, id, 175);
    if (resolved.direction !== "decreasing") continue;
    ok(
      resolved.enterPeak < resolved.enterRest,
      `${id}: band inverted at rest 175 (${resolved.enterPeak} vs ${resolved.enterRest})`,
    );
    ok(
      resolved.romTarget <= resolved.enterPeak,
      `${id}: romTarget above the gate would make every counted rep score 0`,
    );
  }
});

test("resolveThresholds · a different athlete's rest pose shifts all three together", () => {
  // This is the entire point of versioned calibration (api-contract.md §71):
  // absolute angles depend on viewing angle and body proportions, so the
  // athlete's own start pose is the reference. Rest 190 instead of 175 moves
  // every threshold by exactly +15 and changes nothing else.
  const a = resolveThresholds(catalogue, "squat", 175);
  const b = resolveThresholds(catalogue, "squat", 190);
  strictEqual(b.enterPeak - a.enterPeak, 15);
  strictEqual(b.enterRest - a.enterRest, 15);
  strictEqual(b.romTarget - a.romTarget, 15);
  // The band WIDTH is invariant, which is what makes one romScore formula valid
  // for both athletes.
  strictEqual(b.enterRest - b.enterPeak, a.enterRest - a.enterPeak);
  strictEqual(b.enterPeak - b.romTarget, a.enterPeak - a.romTarget);
  strictEqual(b.direction, a.direction);
  strictEqual(b.tolerance, a.tolerance);
});

test("resolveThresholds · ratio signals carry the ratio tolerance, not degrees", () => {
  const t = resolveThresholds(catalogue, "jumping_jack", 0.35);
  strictEqual(t.unit, "ratio");
  strictEqual(t.direction, "increasing");
  // api-contract.md:236 — "15°, or 0.15 for ratio signals".
  strictEqual(t.tolerance, TRACE_TOLERANCE_RATIO);
  strictEqual(t.enterPeak, 1.2);
  strictEqual(t.enterRest, 0.6);
  strictEqual(t.romTarget, 1.6);
  ok(t.enterPeak > t.enterRest, "an increasing signal's band runs the other way");
});

test("toleranceFor · degrees vs ratio", () => {
  strictEqual(toleranceFor("deg"), TRACE_TOLERANCE_DEG);
  strictEqual(toleranceFor("ratio"), TRACE_TOLERANCE_RATIO);
  strictEqual(TRACE_TOLERANCE_DEG, 15);
  strictEqual(TRACE_TOLERANCE_RATIO, 0.15);
});

test("resolveThresholds · a holdTime movement resolves its band and ignores its offsets", () => {
  const t = resolveThresholds(catalogue, "plank", PLANK.rest);
  strictEqual(t.direction, "hold");
  strictEqual(t.movement.measurementType, "holdTime");
  // plank's band is 160–185 (requirements.md §Holds, api-contract.md:131).
  strictEqual(t.holdBand?.low, 160);
  strictEqual(t.holdBand?.high, 185);
  near(t.holdBand?.centre ?? 0, 172.5, 1e-12);
  near(t.holdBand?.halfWidth ?? 0, 12.5, 1e-12);
  // The offsets are placeholders. They still resolve — a hold's thresholds are
  // simply never read by the hold scorer.
  strictEqual(t.enterPeak, PLANK.rest);
  strictEqual(t.enterRest, PLANK.rest);
  strictEqual(t.romTarget, PLANK.rest);
});

test("resolveThresholds · every holdTime movement in the catalogue has a band and direction 'hold'", () => {
  // The regression this guards is real and was found by reading 0003 rather than
  // by running it: `dead_hang` is a holdTime movement in the `pull` family, and
  // an `INSERT ... SELECT` cannot see its own inserted rows, so the family
  // backfill handed it `pull_up`'s −85/−25/−120 with direction 'decreasing'.
  // Without a band, `scoreHoldSet` falls back to a zero-width one and every
  // dead hang scores bandScore 1 — a windfall from a seeding slip.
  for (const [id, movement] of catalogue.movements) {
    if (movement.measurementType !== "holdTime") continue;
    const t = resolveThresholds(catalogue, id, 178);
    strictEqual(t.direction, "hold", `${id}: a holdTime movement must not carry a rep direction`);
    ok(t.holdBand !== null, `${id}: holdTime movement has no in-form band`);
    ok(
      (t.holdBand?.halfWidth ?? 0) > 0,
      `${id}: zero-width band would grade every hold as perfect`,
    );
    strictEqual(t.unit, "deg");
  }
});

test("resolveThresholds · every repBodyweight movement has a real band-free rep config", () => {
  for (const [id, movement] of catalogue.movements) {
    if (movement.measurementType !== "repBodyweight") continue;
    const t = resolveThresholds(catalogue, id, 175);
    strictEqual(t.holdBand, null, `${id}: a rep movement must not carry a hold band`);
    ok(t.direction === "decreasing" || t.direction === "increasing", `${id}: bad direction`);
    ok(
      isDecreasing(t.direction) === (t.direction === "decreasing"),
      `${id}: isDecreasing disagrees`,
    );
  }
});

test("resolveThresholds · difficulty and tier come from the catalogue, frozen Day 1", () => {
  // requirements.md:163 — the difficulty table is frozen on Day 1, so these are
  // literals rather than derived values.
  const expect: Record<string, [number, number]> = {
    assisted_squat: [0.7, 1],
    squat: [1.0, 2],
    jump_squat: [1.5, 3],
    pistol_squat: [2.4, 4],
    knee_push_up: [0.7, 1],
    push_up: [1.0, 2],
    diamond_push_up: [1.4, 3],
    archer_push_up: [2.0, 4],
    dead_hang: [0.8, 1],
    pull_up: [1.8, 2],
    wide_grip_pull_up: [2.2, 3],
    muscle_up: [3.0, 4],
    wall_sit: [0.8, 1],
    plank: [1.0, 2],
    side_plank: [1.3, 3],
    l_sit: [2.2, 4],
    jumping_jack: [0.8, 2],
    burpee: [2.2, 3],
  };
  for (const [id, [difficulty, tier]] of Object.entries(expect)) {
    const movement = catalogue.movements.get(id);
    ok(movement !== undefined, `${id} missing from the catalogue`);
    strictEqual(movement!.difficulty, difficulty, `${id} difficulty`);
    strictEqual(movement!.tier, tier, `${id} tier`);
  }
  strictEqual(catalogue.movements.size, Object.keys(expect).length);
});

test("resolveThresholds · numeric columns arrive as strings and are coerced, not concatenated", () => {
  // PostgREST returns every `numeric` as a string. `restSignal + "−65.0"` in JS
  // is string concatenation, which would produce `"175-65.0"` and then NaN
  // somewhere downstream. This asserts the coercion happened in `buildCatalogue`.
  const row = catalogue.offsets.get("squat");
  ok(row !== undefined, "squat offsets missing");
  strictEqual(typeof row!.enterPeakOffset, "number");
  strictEqual(row!.enterPeakOffset, -65);
  strictEqual(resolveThresholds(catalogue, "squat", 175).enterPeak, 110);
});

test("resolveThresholds · UNKNOWN_MOVEMENT for an id that is not in the catalogue", () => {
  throwsCode(() => resolveThresholds(catalogue, "barbell_squat", 175), "UNKNOWN_MOVEMENT");
  // Calisthenics only is the defining constraint, not a scope cut.
  throwsCode(() => resolveThresholds(catalogue, "bench_press", 175), "UNKNOWN_MOVEMENT");
});

test("resolveThresholds · CONFIG_MISSING_OFFSETS is a distinct code, because it is our bug not theirs", () => {
  // A movement that exists but has no offsets in the bound version means a
  // migration added a movement without seeding it. Distinguishing the two codes
  // is what makes that findable in the logs instead of reading as a bad client.
  const partial: Catalogue = {
    version: CONFIG_VERSION,
    movements: catalogue.movements,
    offsets: new Map(),
  };
  throwsCode(() => resolveThresholds(partial, "squat", 175), "CONFIG_MISSING_OFFSETS");
});

test("CatalogueError · carries its code and is an Error", () => {
  const error = new CatalogueError("UNKNOWN_MOVEMENT", "nope");
  strictEqual(error.code, "UNKNOWN_MOVEMENT");
  strictEqual(error.name, "CatalogueError");
  ok(error instanceof Error, "must be catchable as an Error");
});

test("buildCatalogue · an offset for a movement that does not exist fails the build", () => {
  // A migration bug, not a runtime condition. Failing at catalogue construction
  // beats carrying a row the scorer can never reach. The code is deliberately
  // NOT `UNKNOWN_MOVEMENT`: that one means "the client asked for a movement we
  // do not have", which is a 4xx, whereas this is our own seeding and must read
  // differently in the logs.
  throwsCode(
    () =>
      buildCatalogue(
        CONFIG_VERSION,
        [{
          id: "squat",
          family: "squat",
          tier: 2,
          measurement_type: "repBodyweight",
          difficulty: "1.0",
          hold_band_low: null,
          hold_band_high: null,
        }],
        [{
          movement_id: "ghost",
          enter_peak_offset: "-65.0",
          enter_rest_offset: "-25.0",
          rom_target_offset: "-95.0",
          unit: "deg",
          direction: "decreasing",
        }],
      ),
    "CATALOGUE_MALFORMED",
  );
});

/** The minimum a set needs for `assertResolvable` to reach the checks under test. */
function setRef(movementId: string, measurementType: string) {
  return { movementId, measurementType } as never;
}

function evidenceWith(sets: readonly unknown[]) {
  return {
    sessionId: "x",
    movementConfigVersion: CONFIG_VERSION,
    location: { lat: 0, lng: 0, accuracyM: 8, isMocked: false },
    spotId: null,
    sets,
  } as never;
}

test("assertResolvable · passes when every set's movement can be scored", () => {
  // This runs BEFORE the one-shot session consume: I2 makes a session
  // non-retryable, so a payload that cannot be scored must not burn one.
  assertResolvable(
    catalogue,
    evidenceWith([setRef("squat", "repBodyweight"), setRef("plank", "holdTime")]),
  );
});

test("assertResolvable · an unknown movement is caught before the session is consumed", () => {
  throwsCode(
    () =>
      assertResolvable(
        catalogue,
        evidenceWith([setRef("squat", "repBodyweight"), setRef("barbell_squat", "repBodyweight")]),
      ),
    "UNKNOWN_MOVEMENT",
  );
});

test("assertResolvable · a movement claimed as the wrong measurement type is caught", () => {
  // A plank submitted as `repBodyweight` would score through the rep path with
  // zero reps and silently award nothing — or, worse, be scored against a
  // placeholder offset row. Either outcome is invisible in the response, so it
  // has to be caught here.
  throwsCode(
    () => assertResolvable(catalogue, evidenceWith([setRef("plank", "repBodyweight")])),
    "MEASUREMENT_TYPE_MISMATCH",
  );
  throwsCode(
    () => assertResolvable(catalogue, evidenceWith([setRef("squat", "holdTime")])),
    "MEASUREMENT_TYPE_MISMATCH",
  );
});

test("moreExtreme / atLeastAsExtreme · direction decides which end of the range is extreme", () => {
  // REST and PEAK are not "high" and "low" — a pull-up starts extended and
  // flexes upward, and a jumping jack's ratio rises.
  strictEqual(moreExtreme(80, 110, "decreasing"), 80);
  strictEqual(moreExtreme(80, 110, "increasing"), 110);
  strictEqual(atLeastAsExtreme(80, 85, "decreasing"), true, "80 is deeper than 85");
  strictEqual(atLeastAsExtreme(90, 85, "decreasing"), false, "90 is shallower than 85");
  strictEqual(atLeastAsExtreme(85, 85, "decreasing"), true, "equal is at least as extreme");
  strictEqual(atLeastAsExtreme(1.4, 1.3, "increasing"), true);
  strictEqual(atLeastAsExtreme(1.2, 1.3, "increasing"), false);
  // 'hold' falls through to the increasing branch of both helpers, because
  // `isDecreasing` is a single equality test. That is fine and should stay fine:
  // `crossCheckTrace` bails out on a holdTime set before either is called, and
  // `scoreHold` grades against the band rather than against an extreme. The
  // assertions here document the fall-through so a future change to it is a
  // deliberate one.
  strictEqual(moreExtreme(80, 110, "hold"), 110);
  strictEqual(atLeastAsExtreme(80, 85, "hold"), false);
  strictEqual(atLeastAsExtreme(90, 85, "hold"), true);
});
