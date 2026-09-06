/// H3 hex resolution — server-side only (docs/backend-scaffolding.md §2, and
/// requirements.md §8 open-1: "H3 hexes computed server-side. The client draws
/// plain coordinate polygons — no H3 library needed on the client").
///
/// Deno-only: `npm:` specifier. Nothing in the pure tree imports this.

import { latLngToCell } from "npm:h3-js@4";

/**
 * Resolution 8 — average hexagon area ~0.737 km², the number quoted throughout
 * the docs. Frozen: changing resolution re-keys every hex in the game and
 * orphans all captured territory, so it is a migration, not a constant to tune.
 */
export const H3_RESOLUTION = 8;

/**
 * Resolves a coordinate to its hex index.
 *
 * h3-js throws on an out-of-range latitude or longitude rather than wrapping, so
 * the range is checked first. That check belongs here and not in the session
 * gates because it is a property of the H3 library, not of GPS plausibility —
 * and because a future caller (spot creation) needs the same guard.
 */
export function hexFor(lat: number, lng: number): string {
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) {
    throw new RangeError(`latitude out of range: ${lat}`);
  }
  if (!Number.isFinite(lng) || lng < -180 || lng > 180) {
    throw new RangeError(`longitude out of range: ${lng}`);
  }
  return latLngToCell(lat, lng, H3_RESOLUTION);
}
