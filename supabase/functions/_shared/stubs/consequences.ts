/// The C4 consequence block — "all consequences in one response".
///
/// SCOPE NOTE. This slice implements counting and verification, not territory.
/// The scoring half of C4 (`xp`) is real: it comes straight out of the ledger
/// write. The territory half below is a thin deterministic stand-in, because the
/// tables it would read (`spot_holders`, `personal_records`, the XP curve) do not
/// exist in this migration set. `hexResult` is the ONE exception: the live submit
/// path now computes it from the real contributions ledger (migration 0007) and
/// passes it in via `ConsequenceInput.hexResultOverride`; the stand-in here remains
/// only as the non-live / golden default.
///
/// Two rules were non-negotiable even for a stand-in:
///
///   1. DETERMINISTIC. Every field is a pure function of the score and the
///      session's stored context. No `Math.random`, no clock. A golden fixture
///      that asserted a random hex flip would be worthless, and so would a demo
///      that behaved differently on the second run.
///   2. NEVER FABRICATE A CLAIM. Anything that would assert a fact this backend
///      cannot know — that a rank moved, that a personal record fell, that a tier
///      unlocked — returns empty rather than plausible. An empty `prs` array is
///      an unimplemented feature; a fabricated one is a lie on stage.
///
/// Each stub below names the exact dependency that replaces it.

import type { EvidenceScore } from "../scoring/score.ts";

/**
 * PLACEHOLDER XP CURVE — B-15 owns the real one.
 *
 * Linear so it is obviously a placeholder to anyone reading a summary screen, and
 * monotone so `levelUps` can never go backwards when the real curve lands.
 */
export const XP_PER_LEVEL = 250;

export function levelForXp(xp: number): number {
  return 1 + Math.floor(Math.max(0, xp) / XP_PER_LEVEL);
}

/** The levels crossed between two XP totals, ascending. Empty when none. */
export function levelsCrossed(priorXp: number, newXp: number): number[] {
  const from = levelForXp(priorXp);
  const to = levelForXp(newXp);
  const crossed: number[] = [];
  for (let level = from + 1; level <= to; level++) crossed.push(level);
  return crossed;
}

export interface HexResultOut {
  h3: string;
  captured: boolean;
  power: number;
  yourPower: number;
}

export interface SpotResultOut {
  spotId: string;
  captured: boolean;
  rank: number;
}

export interface RankChangeOut {
  before: number;
  after: number;
}

export interface PersonalRecordOut {
  movementId: string;
  /** max reps / max hold / hardest tier (requirements.md E5). */
  metric: string;
  value: number;
}

export interface ConsequenceInput {
  /** `workout_sessions.start_h3` — the server-recorded context, never the submitted one. */
  h3: string;
  /** `workout_sessions.spot_id`. */
  spotId: string | null;
  score: EvidenceScore;
  /** Lifetime XP *before* this submission, for the level-up delta. */
  priorLifetimeXp: number;
  /**
   * The REAL territory result, computed by the live submit path from the
   * contributions ledger (session-submit step 9). When present — including as an
   * explicit `null` meaning "scored, but no territory claim registered" — it
   * REPLACES the deterministic stub below. Absent (`undefined`) keeps the stub, so
   * every existing golden fixture and the non-live path are byte-for-byte unchanged.
   */
  hexResultOverride?: HexResultOut | null;
}

/**
 * The `POST /session/submit` response body — the C4 everything-response.
 *
 * One shape for both the live path and the stub, so the client deserialises the
 * same object whichever is serving. Fields this slice cannot compute are typed as
 * nullable or as arrays rather than dropped, because `SubmitResult` in
 * `lib/models/models.dart` declares them all as required — the key must exist.
 *
 * NOTE: models.dart has no `fromJson` yet (backend-scaffolding.md §8 is still
 * outstanding on the client side), so these keys are currently asserted against
 * the constructor signatures by eye. Keep the names identical when it is written.
 */
export interface Consequences {
  xp: number;
  level: number;
  levelUps: number[];
  hexResult: HexResultOut | null;
  spotResult: SpotResultOut | null;
  rankChange: RankChangeOut | null;
  unlocks: string[];
  prs: PersonalRecordOut[];
  achievements: string[];
  voided: boolean;
}

export function buildConsequences(input: ConsequenceInput): Consequences {
  const awarded = input.score.awardedTotal;
  const xp = input.score.xp;

  // A session that scored nothing changed no territory. Returning a hexResult
  // with power 0 would make the summary screen celebrate a capture that did not
  // happen — the tier-gated and fully-capped cases both land here.
  const captured = awarded > 0;

  return {
    xp,
    level: levelForXp(input.priorLifetimeXp + xp),
    levelUps: levelsCrossed(input.priorLifetimeXp, input.priorLifetimeXp + xp),

    // The live path passes `hexResultOverride`, computed from the ledger; when it
    // is present (even as null) it wins. Otherwise this is the STUB used by the
    // non-live path and the goldens. Real version once override is always supplied:
    // upsert into the hex claim table keyed on `h3`, add `awarded` to this user's
    // power there, subtract decayed power from the previous holder, and return the
    // hex's TOTAL power alongside this user's contribution. Without that, the two
    // are the same number, which is why `power === yourPower` here — visibly wrong
    // the moment contest exists, and therefore impossible to mistake for finished.
    hexResult: input.hexResultOverride !== undefined
      ? input.hexResultOverride
      : captured
      ? { h3: input.h3, captured: true, power: awarded, yourPower: awarded }
      : null,

    // STUB. Real version: read `spot_holders` for this spot, rank by power, and
    // report the user's position. `rank: 1` is asserted only because a session
    // opened at a spot the athlete just scored in is, on an uncontested demo
    // board, first — not because a board was consulted.
    spotResult: input.spotId !== null && captured
      ? { spotId: input.spotId, captured: true, rank: 1 }
      : null,

    // Needs `territory_leaderboard`. A rank change cannot be derived from one
    // session in isolation, so it is null rather than guessed.
    rankChange: null,

    // Needs the variation-tree progression rules (B-14): reps-toward-next-tier
    // thresholds per family. Emitting an unlock here would let an athlete score
    // a tier they never earned, which is exactly what I10 forbids.
    unlocks: [],

    // Needs a lifetime aggregate over `rep_events` / `set_records` per movement.
    // This session's best is NOT a personal record, and reporting it as one
    // would be the most visible kind of wrong on a summary screen.
    prs: [],

    // Needs the achievement table. Cut order in AGENTS.md puts achievements
    // first when behind schedule, so this stays empty by design.
    achievements: [],

    // Always false on the write path. Voiding is retroactive and human-triggered
    // via `void_session()` (I12, I13) — a submission is never born voided.
    voided: false,
  };
}
