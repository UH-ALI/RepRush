/// H3 hex resolution — server-side only (docs/backend-scaffolding.md §2, and
/// requirements.md §8 open-1: "H3 hexes computed server-side. The client draws
/// plain coordinate polygons — no H3 library needed on the client").
///
/// Deno-only: `npm:` specifier. Nothing in the pure tree imports this.

import { cellToBoundary, latLngToCell, polygonToCells } from "npm:h3-js@4";

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

/** A closed lat/lng vertex loop, the shape h3-js's polygon functions take. */
export type LatLngLoop = [number, number][];

/**
 * Every res-8 cell whose CENTRE falls inside a bbox (B-10 — the server computes
 * the grid; the client only ever receives plain coordinate polygons).
 *
 * `polygonToCells` rather than a `gridDisk` around the centre: a disk of any fixed
 * radius under-covers a bbox larger than a handful of cells (the map's bbox is
 * bounded only by the route's `BBOX_TOO_LARGE` checks, not by a small radius),
 * whereas `polygonToCells` returns exactly the contained cells for any box size.
 * Centre-containment is the standard choice for a display grid and matches how the
 * four corners are enumerated into a closed loop below (SW → NW → NE → SE).
 *
 * The bbox is validated by the caller (finite, `ne > sw`, within the degree and
 * cell-count caps) before this runs; h3-js itself throws on an out-of-range vertex,
 * which the route maps to a 400 rather than a 500.
 */
export function cellsCoveringBBox(
  swLat: number,
  swLng: number,
  neLat: number,
  neLng: number,
): string[] {
  const loop: LatLngLoop = [
    [swLat, swLng],
    [neLat, swLng],
    [neLat, neLng],
    [swLat, neLng],
  ];
  return polygonToCells(loop, H3_RESOLUTION, false);
}

/**
 * The boundary of one cell as `[lat, lng]` vertices, counter-clockwise from a
 * vertex — h3-js's native order and format. The route maps each pair to a
 * `{ lat, lng }` point for the client's `HexPolygon`; no H3 maths reaches the
 * client (requirements.md §8 open-1).
 */
export function hexBoundary(h3: string): LatLngLoop {
  return cellToBoundary(h3) as LatLngLoop;
}
