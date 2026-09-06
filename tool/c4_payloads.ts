/// Prints the exact bytes the two session routes put on the wire.
///
///     node tool/c4_payloads.ts
///     deno task c4
///
/// WHY THIS EXISTS
/// `test/models_test.dart` asserts the Dart `fromJson`/`toJson` against literal
/// JSON strings. Those literals are transcribed from THIS output, not from a
/// reading of api-contract.md. That distinction is the whole point: a Dart test
/// that fed `toJson` back into `fromJson` would pass no matter which field names
/// the server actually used, and the field names are the one thing worth checking
/// across a seam with no shared build step.
///
/// Re-run this after any change to `stubs/consequences.ts`,
/// `stubs/session-start.ts` or the score projection, and re-transcribe the
/// literals. If the two ever disagree silently, the failure surfaces on the Day-3
/// swap to live endpoints as a rendering bug rather than as a diff.
///
/// Neither the Flutter nor the Dart SDK is installed on the machine this was
/// written on, so the Dart half of the seam cannot be compiled or tested here.
/// This script is the only executable link between the two languages.

import { FIXTURES, VENUE_H3 } from "../test/server/tools/fixtures.ts";
import { evaluate } from "../test/server/tools/build_fixtures.ts";
import { buildConsequences } from "../supabase/functions/_shared/stubs/consequences.ts";
import { stubStart } from "../supabase/functions/_shared/stubs/session-start.ts";
import type { EvidenceScore } from "../supabase/functions/_shared/scoring/score.ts";

/** A fixed clock, so the start payload below is byte-stable across runs. */
const NOW_MS = 1_757_000_000_000;
const SPOT_ID = "spot_riverside_rig";

function show(label: string, payload: unknown): void {
  console.log(`\n=== ${label}`);
  console.log(JSON.stringify(payload));
}

// ---------------------------------------------------------------------------
// POST /session/start
// ---------------------------------------------------------------------------

show(`session/start · stubStart(${NOW_MS})`, stubStart(NOW_MS));

// ---------------------------------------------------------------------------
// POST /session/submit — every authored fixture
// ---------------------------------------------------------------------------

for (const { name, fixture } of FIXTURES) {
  const golden = evaluate(fixture);

  if (golden.gate !== null) {
    // The gate envelope. The message is illustrative — the real one is built by
    // the validator from the two durations — but `code` and the status are the
    // contract, and those are the golden's.
    console.log(`\n=== ${name} — GATE ${golden.gate.status}`);
    console.log(JSON.stringify({ code: golden.gate.code, message: "…" }));
    continue;
  }

  // buildConsequences reads only awardedTotal and xp off the score, so the
  // projected golden score is enough — no need to reconstruct an EvidenceScore.
  const score = golden.score as unknown as EvidenceScore;

  // Two prior-XP values: one that crosses no level and one that does, so the
  // Dart side is tested against `levelUps` both empty and populated.
  show(
    `${name} · priorXp 0`,
    buildConsequences({
      h3: VENUE_H3,
      spotId: null,
      score,
      priorLifetimeXp: 0,
    }),
  );
  show(
    `${name} · priorXp 240`,
    buildConsequences({
      h3: VENUE_H3,
      spotId: null,
      score,
      priorLifetimeXp: 240,
    }),
  );
}

// ---------------------------------------------------------------------------
// The branches no fixture reaches
// ---------------------------------------------------------------------------

/**
 * THE INT-VALUED DOUBLE, and the reason models.dart coerces instead of casting.
 *
 * `awardedTotal` here is exactly 6 — reachable as 20 reps × 0.60 formFactor
 * floor × 0.50 tempo floor. `JSON.stringify` emits a JS number with no
 * fractional part as `6`, not `6.0`, so Dart's `json['power'] as double` throws
 * `type 'int' is not a subtype of type 'double'`. Look for `"power":6` below.
 */
show(
  "awardedTotal 6 · integral, emits power as an int",
  buildConsequences({
    h3: VENUE_H3,
    spotId: null,
    score: { awardedTotal: 6, xp: 6 } as unknown as EvidenceScore,
    priorLifetimeXp: 0,
  }),
);

/** A capture at a named spot, so `spotResult` is populated rather than null. */
show(
  "spot capture · spotResult populated",
  buildConsequences({
    h3: VENUE_H3,
    spotId: SPOT_ID,
    score: { awardedTotal: 19.63992, xp: 20 } as unknown as EvidenceScore,
    priorLifetimeXp: 0,
  }),
);

/**
 * The tier-gated / fully-capped branch. `hexResult` must be NULL here, not
 * present with `power: 0` — a summary screen reading the latter would celebrate
 * a capture that did not happen.
 */
show(
  "awarded 0 · no capture reported",
  buildConsequences({
    h3: VENUE_H3,
    spotId: SPOT_ID,
    score: { awardedTotal: 0, xp: 0 } as unknown as EvidenceScore,
    priorLifetimeXp: 0,
  }),
);

console.log(`
NOT PRODUCIBLE BY THIS BACKEND — written into the Dart test from the TypeScript
interfaces instead, and marked as such there:
  prs         buildConsequences always returns []. Needs a lifetime aggregate
              over rep_events / set_records per movement.
  rankChange  always null. Needs territory_leaderboard; a rank change cannot be
              derived from one session in isolation.
  unlocks     always []. Needs the variation-tree progression rules (B-14).
`);
