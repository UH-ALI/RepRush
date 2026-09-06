/// Location plausibility — the accuracy gate (D4), the mock-location rule (I7)
/// and the implied-travel check (I7). Pure maths, no I/O.
///
/// N7 constrains what may be stored: location lives as an H3 index plus a coarse
/// timestamp, never a raw GPS trace. One fix per session, recorded at start.

export const EARTH_RADIUS_M = 6371008.8;

/** D4 — beyond this the session earns no territory credit. */
export const MAX_GPS_ACCURACY_M = 50;

/** I7 — implied travel above this between session events is a teleport. */
export const MAX_TRAVEL_SPEED_KMH = 40;

/**
 * Session-context match radius. The Evidence location must land this close to the
 * server-recorded session-start fix, or the submission is rejected with
 * SESSION_CONTEXT_MISMATCH.
 *
 * 100 m is the spot proximity radius (E2) reused deliberately: it is wider than
 * real GPS drift over a few minutes and far tighter than the distance to a
 * different hex. An athlete who walks out of frame mid-session still matches.
 */
export const CONTEXT_MATCH_RADIUS_M = 100;

const toRad = (deg: number): number => (deg * Math.PI) / 180;

/** Great-circle distance in metres. */
export function haversineM(
  aLat: number,
  aLng: number,
  bLat: number,
  bLng: number,
): number {
  const dLat = toRad(bLat - aLat);
  const dLng = toRad(bLng - aLng);
  const s = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(aLat)) * Math.cos(toRad(bLat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(s)));
}

export interface TravelCheck {
  ok: boolean;
  distanceM: number;
  elapsedMs: number;
  speedKmh: number | null;
}

/**
 * Implied speed between two fixes. `elapsedMs <= 0` is treated as a teleport
 * rather than a division by zero: two session events at the same instant in
 * different places is exactly the case I7 exists to catch.
 *
 * Under MIN_MEANINGFUL_ELAPSED_MS the speed estimate is dominated by GPS jitter
 * rather than movement, so a short interval only fails on raw distance.
 */
export const MIN_MEANINGFUL_ELAPSED_MS = 30_000;

export function impliedTravel(
  fromLat: number,
  fromLng: number,
  toLat: number,
  toLng: number,
  elapsedMs: number,
): TravelCheck {
  const distanceM = haversineM(fromLat, fromLng, toLat, toLng);

  if (elapsedMs <= 0) {
    return { ok: distanceM <= CONTEXT_MATCH_RADIUS_M, distanceM, elapsedMs, speedKmh: null };
  }

  const speedKmh = (distanceM / 1000) / (elapsedMs / 3_600_000);
  if (elapsedMs < MIN_MEANINGFUL_ELAPSED_MS) {
    // Too short an interval to rate a speed; only an outright jump fails.
    return { ok: distanceM <= CONTEXT_MATCH_RADIUS_M, distanceM, elapsedMs, speedKmh };
  }
  return { ok: speedKmh <= MAX_TRAVEL_SPEED_KMH, distanceM, elapsedMs, speedKmh };
}
