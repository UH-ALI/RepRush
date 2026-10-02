/// Presence rules — who counts as visible, and how close is "nearby". Pure, so
/// it loads under plain Node; the H3 half (rings, centres) is in `h3.ts`.

/**
 * A heartbeat older than this no longer shows you. The client beats every
 * 15 s, so one or two dropped requests never blink anyone off the map, while
 * an athlete who closes the app is gone within two minutes.
 */
export const PRESENCE_TTL_MS = 120_000;

/**
 * Res-8 rings around your hex that count as "nearby" — k = 3 is 37 cells,
 * roughly 1.5 km in every direction: walking distance to go and meet someone.
 */
export const NEARBY_RING_K = 3;

/**
 * Looser than the 50 m session gate (D4), deliberately. Presence places you in
 * a ~460 m-wide hex for display, and nothing is scored from it; refusing a
 * 70 m indoor fix would hide exactly the athletes standing in a gym.
 */
export const PRESENCE_MAX_ACCURACY_M = 150;

/** True when a row last beaten at [updatedAtMs] is still visible at [nowMs]. */
export function isFresh(updatedAtMs: number, nowMs: number): boolean {
  return nowMs - updatedAtMs < PRESENCE_TTL_MS;
}
