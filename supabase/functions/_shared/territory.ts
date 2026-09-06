/// Territory maths — the 72 h half-life decay, capture resolution and flip
/// detection (B-9; requirements.md D2, D3, §5).
///
/// PURE, and that is load-bearing rather than stylistic. No I/O, no clock (the
/// caller passes `nowMs`), no randomness, and no `npm:`/Deno import — so this file
/// loads under plain Node and the decay/capture rules are unit-testable in
/// `test/server/territory_test.ts` without a database or a Deno install. The H3
/// geometry lives in `_shared/h3.ts` (Deno-only, `npm:h3-js`) and the SQL in
/// `_shared/repo.ts`; neither is imported here.
///
/// THE RULE THIS FILE ENCODES (migration 0007 header): power is never stored
/// decayed. A contribution is an immutable (amount, earnedAt) pair, and current
/// power is reconstructed on every read as Σ amount × 0.5^(age / 72 h). That is
/// what makes D3's "computed lazily on read — don't run a cron" true: nothing here
/// mutates a stored total, because there is no stored total to mutate.

import { envOr } from "./env.ts";

/**
 * The 72 h half-life (D3), in milliseconds. The single definition in the
 * codebase — `_shared/territory.ts` is where "72 hours" is written down, and
 * everything else reads it from here.
 */
export const HALF_LIFE_MS = 72 * 3_600_000;

/**
 * Average area of a res-8 hexagon in km². h3-js quotes ~0.737 for the resolution
 * the docs froze (`_shared/h3.ts`); the leaderboard's `areaKm2` is `held × this`.
 */
export const RES8_AREA_KM2 = 0.737;

/**
 * D2's "minimum RepScore at the target to register a claim" — the line that stops
 * a single drive-by rep taking a hex. The docs fix the RULE but not the number, so
 * it is ours to pick and is env-tunable: 10 is comfortably a real set's worth
 * (a clean 20-rep squat scores ~20) and comfortably above one rep (~0.6–1.8).
 *
 * Read lazily through a function, not captured at module load, so the pure
 * resolvers below take it as a parameter and stay deterministic in tests. A
 * non-finite or negative env value falls back to the default rather than letting a
 * typo disable claiming entirely (0) or make it impossible (NaN comparisons).
 */
export function minClaimPower(): number {
  const parsed = Number(envOr("REPRUSH_MIN_CLAIM_POWER", "10"));
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : 10;
}

/**
 * The decay multiplier for a contribution earned at `earnedAtMs`, read at `nowMs`.
 * Exactly 1 at age zero, 0.5 at one half-life, 0.25 at two.
 *
 * A negative age (a future-dated `earned_at`, which a server clock skew could in
 * principle produce) clamps to 1 rather than returning a factor > 1: decay may
 * reduce what was earned but must never amplify it, and an amplified contribution
 * would let a mis-dated row out-score an honest one.
 */
export function decayFactor(earnedAtMs: number, nowMs: number): number {
  const age = nowMs - earnedAtMs;
  if (age <= 0) return 1;
  return Math.pow(0.5, age / HALF_LIFE_MS);
}

/** One live contribution, as the resolver needs it — already past the view's filter. */
export interface Contribution {
  userId: string;
  /** The frozen RepScore awarded when it was earned. Never decayed in storage. */
  power: number;
  earnedAtMs: number;
}

/**
 * Sums every contribution's DECAYED power per user. This is the lazy-decay read
 * (D3): the totals are reconstructed here from (amount, age) at `nowMs`, and no
 * stored value was consulted or mutated to produce them.
 *
 * Contributions for a single hex only — the caller groups by h3 first. A hex has a
 * handful of rows, so this is cheap; the leaderboard avoids calling it per cell by
 * reading the materialised `hex_ownership` cache instead.
 */
export function resolveHexPower(
  contributions: readonly Contribution[],
  nowMs: number,
): Map<string, number> {
  const totals = new Map<string, number>();
  for (const c of contributions) {
    const decayed = c.power * decayFactor(c.earnedAtMs, nowMs);
    totals.set(c.userId, (totals.get(c.userId) ?? 0) + decayed);
  }
  return totals;
}

/** The winner of a hex: highest decayed power at or above the claim threshold. */
export interface Owner {
  userId: string;
  power: number;
}

/**
 * Argmax over per-user power, gated by [minPower] (D2). Returns null when nobody
 * reaches the threshold — an empty hex, or one whose contributions have all decayed
 * below the line. Null is the "unclaimed" state the map renders, and the reason a
 * hex can go back to open without anyone capturing it: decay alone can vacate it.
 *
 * Ties keep the earlier-inserted user (`power > best.power`, strict): Map iteration
 * is insertion order, so the first athlete to reach a power holds it against a later
 * equal claim rather than the cell flickering between them.
 */
export function resolveOwner(
  powers: ReadonlyMap<string, number>,
  minPower: number,
): Owner | null {
  let best: Owner | null = null;
  for (const [userId, power] of powers) {
    if (power < minPower) continue;
    if (best === null || power > best.power) best = { userId, power };
  }
  return best;
}

/** The materialised `hex_ownership` row the write path compares against. */
export interface MaterialisedOwner {
  ownerId: string;
  ownerPower: number;
}

export interface FlipDecision {
  /** True when the `hex_ownership` cache must be rewritten (or cleared). */
  changed: boolean;
  /** True when a `hex_flips` row must be appended — the holder IDENTITY changed. */
  flipped: boolean;
  /** Previous holder for the flip row; null on a first-ever capture. */
  fromUserId: string | null;
  /** True when the change is a clear (holder decayed below threshold), not a write. */
  cleared: boolean;
}

const NO_CHANGE: FlipDecision = {
  changed: false,
  flipped: false,
  fromUserId: null,
  cleared: false,
};

/**
 * Compares a freshly resolved owner against the materialised cache row and decides
 * what the WRITE path (session-submit) must persist. It never touches the database
 * — it is the pure decision; the caller executes it.
 *
 * Called on submit, not on read: a read recomputes power from the ledger for
 * display and must not have side effects, while the cache exists so the LEADERBOARD
 * is a cheap indexed read (0007 header). The three cases:
 *
 *   resolved null, no cache        → nothing; the hex is and stays unclaimed.
 *   resolved null, cache present   → the holder decayed below the threshold with no
 *                                    new claim: clear the cache (changed), but append
 *                                    NO flip — `hex_flips.to_user_id` is NOT NULL, and
 *                                    a decay-to-unclaimed is not a capture by anyone.
 *   resolved set, holder differs   → a capture: rewrite the cache and append a flip
 *                                    (from the previous holder, or null if first-ever).
 *   resolved set, holder identical → refresh the cached power only if it moved, so a
 *                                    re-submit by the standing owner updates the number
 *                                    without logging a flip that did not happen.
 */
export function detectFlip(
  materialised: MaterialisedOwner | null,
  resolved: Owner | null,
): FlipDecision {
  if (resolved === null) {
    if (materialised === null) return NO_CHANGE;
    return { changed: true, flipped: false, fromUserId: materialised.ownerId, cleared: true };
  }

  if (materialised === null) {
    // First-ever capture of this cell.
    return { changed: true, flipped: true, fromUserId: null, cleared: false };
  }

  if (materialised.ownerId !== resolved.userId) {
    // The cell changed hands.
    return {
      changed: true,
      flipped: true,
      fromUserId: materialised.ownerId,
      cleared: false,
    };
  }

  // Same holder. Rewrite the cache only if the power actually moved; never a flip.
  const moved = materialised.ownerPower !== resolved.power;
  return { changed: moved, flipped: false, fromUserId: null, cleared: false };
}

/**
 * The ownership colour token the client already renders — the SAME vocabulary
 * `StubTerritoryRepository` and `map_screen.dart`'s legend use ('mine' / 'rival' /
 * 'unclaimed'), so swapping the map from stub to live changes no rendering code on
 * C's side. Not a hex colour: the design system (N9) resolves the token to a colour
 * that never carries meaning alone.
 */
export type OwnerColor = "mine" | "rival" | "unclaimed";

export function ownerColor(yours: boolean, claimed: boolean): OwnerColor {
  if (!claimed) return "unclaimed";
  return yours ? "mine" : "rival";
}
