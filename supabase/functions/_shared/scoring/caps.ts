/// Caps and rate limits (I11, requirements.md §4 "Caps and curves").
///
/// Two different instruments that are easy to conflate:
///
///   - The per-set cap and the per-day diminishing returns are SCORING. They
///     reduce points and never reject, because a legitimate 300-rep set should
///     still score something rather than fail.
///   - The daily session count is a RATE LIMIT. It does reject, with 429, because
///     its job is to bound how much work the server does for one account.
///
/// I13's "shadow-flag, don't hard-ban" applies to plausibility judgements — the
/// ones where a false positive means a judge gets locked out mid-demo. A rate
/// limit is not a plausibility judgement, so it is allowed to say no.

/** One 500-rep set cannot own the city. A genuine 50-rep pull-up set still fits. */
export const PER_SET_CAP = 150;

/** RepScore per UTC day earned at full rate. */
export const DAY_FULL_UNTIL = 600;
/** RepScore per UTC day earned at half rate; above this, the tail rate. */
export const DAY_HALF_UNTIL = 1200;
export const DAY_HALF_RATE = 0.5;
export const DAY_TAIL_RATE = 0.25;

/** The 21st session-start in a UTC day is refused. */
export const MAX_SESSIONS_PER_DAY = 20;

export function capSet(repScore: number): number {
  return Math.min(repScore, PER_SET_CAP);
}

/**
 * Marginal-band daily cap. Returns how much of `raw` survives given
 * `alreadyEarned` earlier today.
 *
 * Marginal rather than a flat multiplier on the whole day's total, so a session
 * that straddles a boundary is split correctly instead of being retroactively
 * re-rated — otherwise crossing 600 would silently halve everything earned
 * before it, which reads as a bug to the user and makes the ledger inconsistent
 * with the response that was already sent.
 *
 *   already = 0,    raw = 1000 → 600 + 400×0.5            = 800
 *   already = 700,  raw = 100  → 100×0.5                  = 50
 *   already = 1300, raw = 100  → 100×0.25                 = 25
 */
export function applyDailyCap(raw: number, alreadyEarned: number): number {
  if (raw <= 0) return 0;
  const earned = Math.max(0, alreadyEarned);

  const fullRoom = Math.max(0, DAY_FULL_UNTIL - earned);
  const halfRoom = Math.max(0, DAY_HALF_UNTIL - Math.max(earned, DAY_FULL_UNTIL));

  const atFull = Math.min(raw, fullRoom);
  const remaining = raw - atFull;

  const atHalf = Math.min(remaining, halfRoom);
  const atTail = remaining - atHalf;

  return atFull + atHalf * DAY_HALF_RATE + atTail * DAY_TAIL_RATE;
}

/** True when the daily cap actually bit — worth an `info` flag, not a warning. */
export function dailyCapApplied(raw: number, alreadyEarned: number): boolean {
  return raw > 0 && applyDailyCap(raw, alreadyEarned) < raw - 1e-9;
}
