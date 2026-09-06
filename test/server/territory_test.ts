/// The correctness anchor for the territory maths — the 72 h half-life decay,
/// capture resolution and flip detection (B-9; requirements.md D2, D3, §5).
///
/// WHY THIS FILE CAN RUN WITHOUT A DATABASE OR DENO
/// `_shared/territory.ts` is pure: no I/O, no clock (`nowMs` is a parameter), no
/// `npm:`/Deno import. So the whole decay-and-capture rule set is asserted here
/// under plain Node, exactly like `scoring_test.ts` asserts the score engine. The
/// H3 geometry (`_shared/h3.ts`, `npm:h3-js`) and the SQL (`_shared/repo.ts`) are
/// NOT imported — the geometry is Deno-only and the SQL needs a live stack; both are
/// exercised by the manual e2e in the plan, not here.
///
/// Every assertion names the rule it comes from. If a rule changes and this file
/// does not, that is the bug.

import {
  type Contribution,
  decayFactor,
  detectFlip,
  HALF_LIFE_MS,
  type MaterialisedOwner,
  ownerColor,
  RES8_AREA_KM2,
  resolveHexPower,
  resolveOwner,
} from "../../supabase/functions/_shared/territory.ts";
import {
  buildConsequences,
  type ConsequenceInput,
} from "../../supabase/functions/_shared/stubs/consequences.ts";
import type { EvidenceScore } from "../../supabase/functions/_shared/scoring/score.ts";
import { deepStrictEqual, near, ok, strictEqual, test } from "./_harness.ts";

/** A fixed "now" so every age below is exact and no assertion depends on the clock. */
const NOW = 1_800_000_000_000;
const HOUR = 3_600_000;

test("HALF_LIFE_MS is exactly 72 hours (D3)", () => {
  strictEqual(HALF_LIFE_MS, 72 * HOUR);
});

test("RES8_AREA_KM2 is the res-8 average the leaderboard multiplies by", () => {
  near(RES8_AREA_KM2, 0.737, 1e-9, "res-8 area");
});

// NOTE: `minClaimPower()` is deliberately NOT asserted here. It reads the
// REPRUSH_MIN_CLAIM_POWER env var, and this suite runs env-free by design
// (`deno run --allow-read`; see run_tests.ts). The D2 threshold GATE it feeds is
// covered directly below by the `resolveOwner(powers, 10)` cases, which take the
// threshold as a parameter and so stay deterministic in both runtimes.

test("decayFactor is 1 / 0.5 / 0.25 at zero, one and two half-lives (D3)", () => {
  near(decayFactor(NOW, NOW), 1, 1e-12, "age 0");
  near(decayFactor(NOW - HALF_LIFE_MS, NOW), 0.5, 1e-12, "age 72h");
  near(decayFactor(NOW - 2 * HALF_LIFE_MS, NOW), 0.25, 1e-12, "age 144h");
});

test("decayFactor halves again at three half-lives", () => {
  near(decayFactor(NOW - 3 * HALF_LIFE_MS, NOW), 0.125, 1e-12, "age 216h");
});

test("decayFactor clamps a future-dated contribution to 1, never amplifies", () => {
  // A negative age (clock skew) must not return a factor > 1: decay reduces what was
  // earned but must never let a mis-dated row out-score an honest one.
  near(decayFactor(NOW + HOUR, NOW), 1, 1e-12, "future earned_at");
});

test("resolveHexPower sums decayed contributions per user", () => {
  const contributions: Contribution[] = [
    // Same user: one fresh 100, one 72h old 100 → 100 + 50 = 150.
    { userId: "u1", power: 100, earnedAtMs: NOW },
    { userId: "u1", power: 100, earnedAtMs: NOW - HALF_LIFE_MS },
    // A rival: 80 fresh.
    { userId: "u2", power: 80, earnedAtMs: NOW },
  ];
  const powers = resolveHexPower(contributions, NOW);
  near(powers.get("u1") ?? NaN, 150, 1e-9, "u1 total");
  near(powers.get("u2") ?? NaN, 80, 1e-9, "u2 total");
  strictEqual(powers.size, 2);
});

test("resolveHexPower of no contributions is an empty map", () => {
  strictEqual(resolveHexPower([], NOW).size, 0);
});

test("resolveOwner picks the argmax above the threshold (D2)", () => {
  const powers = new Map([["u1", 150], ["u2", 80]]);
  const owner = resolveOwner(powers, 10);
  ok(owner !== null, "expected an owner");
  strictEqual(owner?.userId, "u1");
  near(owner?.power ?? NaN, 150, 1e-9, "winner power");
});

test("resolveOwner returns null when nobody reaches the threshold", () => {
  // Both contributions decayed below the line: the hex is unclaimed, which is how a
  // cell vacates without anyone capturing it.
  const powers = new Map([["u1", 5], ["u2", 3]]);
  strictEqual(resolveOwner(powers, 10), null);
});

test("resolveOwner returns null on an empty hex", () => {
  strictEqual(resolveOwner(new Map(), 10), null);
});

test("resolveOwner keeps the first user on an exact tie", () => {
  // Insertion order: u1 reached the power first, so it holds against an equal later
  // claim rather than the cell flickering between them.
  const powers = new Map([["u1", 100], ["u2", 100]]);
  const owner = resolveOwner(powers, 10);
  strictEqual(owner?.userId, "u1");
});

test("a rival's fresh power overtakes a decayed incumbent (the flip case)", () => {
  // Incumbent earned 200, now 144h old → 200 × 0.25 = 50. Rival earned 60 fresh.
  const contributions: Contribution[] = [
    { userId: "incumbent", power: 200, earnedAtMs: NOW - 2 * HALF_LIFE_MS },
    { userId: "rival", power: 60, earnedAtMs: NOW },
  ];
  const powers = resolveHexPower(contributions, NOW);
  near(powers.get("incumbent") ?? NaN, 50, 1e-9, "decayed incumbent");
  const owner = resolveOwner(powers, 10);
  strictEqual(owner?.userId, "rival", "fresh rival should now hold the hex");
});

test("detectFlip: resolved null + no cache is a no-op", () => {
  const decision = detectFlip(null, null);
  strictEqual(decision.changed, false);
  strictEqual(decision.flipped, false);
  strictEqual(decision.cleared, false);
});

test("detectFlip: resolved null + a cache row clears it, but logs NO flip", () => {
  // The holder decayed below threshold with no new claim: clear the cache, but
  // hex_flips.to_user_id is NOT NULL and a decay-to-unclaimed is nobody's capture.
  const materialised: MaterialisedOwner = { ownerId: "u1", ownerPower: 40 };
  const decision = detectFlip(materialised, null);
  strictEqual(decision.changed, true);
  strictEqual(decision.flipped, false);
  strictEqual(decision.cleared, true);
  strictEqual(decision.fromUserId, "u1");
});

test("detectFlip: first-ever capture flips from null", () => {
  const decision = detectFlip(null, { userId: "u1", power: 120 });
  strictEqual(decision.changed, true);
  strictEqual(decision.flipped, true);
  strictEqual(decision.fromUserId, null);
  strictEqual(decision.cleared, false);
});

test("detectFlip: a different holder flips from the previous one", () => {
  const materialised: MaterialisedOwner = { ownerId: "u1", ownerPower: 50 };
  const decision = detectFlip(materialised, { userId: "u2", power: 60 });
  strictEqual(decision.changed, true);
  strictEqual(decision.flipped, true);
  strictEqual(decision.fromUserId, "u1");
  strictEqual(decision.cleared, false);
});

test("detectFlip: same holder, unchanged power writes nothing (idempotence)", () => {
  // Re-resolving an unchanged state must not rewrite the cache or log a flip.
  const materialised: MaterialisedOwner = { ownerId: "u1", ownerPower: 100 };
  const decision = detectFlip(materialised, { userId: "u1", power: 100 });
  strictEqual(decision.changed, false);
  strictEqual(decision.flipped, false);
});

test("detectFlip: same holder, moved power refreshes the cache without a flip", () => {
  const materialised: MaterialisedOwner = { ownerId: "u1", ownerPower: 100 };
  const decision = detectFlip(materialised, { userId: "u1", power: 130 });
  strictEqual(decision.changed, true, "cache power should refresh");
  strictEqual(decision.flipped, false, "the holder did not change, so no flip");
});

test("ownerColor returns the client's token vocabulary", () => {
  // The SAME tokens StubTerritoryRepository and map_screen.dart use, so the live
  // swap changes no rendering code on C's side.
  strictEqual(ownerColor(true, true), "mine");
  strictEqual(ownerColor(false, true), "rival");
  strictEqual(ownerColor(false, false), "unclaimed");
  strictEqual(ownerColor(true, false), "unclaimed", "unclaimed wins over yours");
});

// ---------------------------------------------------------------------------
// buildConsequences — the hexResult override must not disturb the golden default
// ---------------------------------------------------------------------------

/** A minimal awarded score; the fields buildConsequences actually reads. */
function score(awardedTotal: number): EvidenceScore {
  return { sets: [], rawTotal: awardedTotal, awardedTotal, xp: awardedTotal, flags: [] };
}

function input(awardedTotal: number): ConsequenceInput {
  return { h3: "88195da49bfffff", spotId: null, score: score(awardedTotal), priorLifetimeXp: 0 };
}

test("buildConsequences with NO override keeps the stub hexResult (golden-compatible)", () => {
  // The whole reason the override is optional: every existing golden asserts this
  // exact stub shape (power === yourPower === awarded), and it must not move.
  const out = buildConsequences(input(20));
  deepStrictEqual(out.hexResult, {
    h3: "88195da49bfffff",
    captured: true,
    power: 20,
    yourPower: 20,
  });
});

test("buildConsequences uses the override verbatim when supplied", () => {
  const override = { h3: "88195da49bfffff", captured: false, power: 1240, yourPower: 620 };
  const out = buildConsequences({ ...input(620), hexResultOverride: override });
  deepStrictEqual(out.hexResult, override, "the live hexResult must pass through untouched");
});

test("buildConsequences honours an explicit null override (scored, no capture)", () => {
  // A territory write that degraded to null must stay null even though awarded > 0,
  // so the summary screen does not celebrate a capture that did not register.
  const out = buildConsequences({ ...input(20), hexResultOverride: null });
  strictEqual(out.hexResult, null);
});
