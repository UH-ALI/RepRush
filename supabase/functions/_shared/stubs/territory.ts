/// The canned `GET /territory/*` responses for the non-live path — the same
/// deploy-safety fallback `session-start`/`session-submit` use
/// (docs/backend-scaffolding.md §6): the route is deployed and reachable before
/// `territory` is added to `LIVE_ENDPOINTS`, and answers realistic canned JSON
/// rather than 404ing, so a rollback on demo day is a flag flip, not a redeploy.
///
/// Deno-only, unlike the other stubs: it imports `_shared/h3.ts` for real res-8
/// geometry. That is fine because its only importer is `territory/index.ts`, which
/// is Deno-only already, and no Node test asserts these bytes.
///
/// The fallback emits the same real H3 cells and boundaries as the live route,
/// differing only in that ownership is deterministic demo data rather than read
/// from the ledger.

import { cellsCoveringBBox, hexBoundary } from "../h3.ts";
import { VENUE } from "./venue.ts";

/** Rival handles, matching the client stub's vocabulary so a swap reads the same. */
const RIVALS = ["rival_kat", "iron_meridian", "parkside_crew"] as const;

export interface StubHexCell {
  h3: string;
  polygon: [number, number][];
  ownerHandle: string | null;
  ownerColor: "mine" | "rival" | "unclaimed";
  power: number;
  yours: boolean;
}

/** A point on the wire is `{ lat, lng }`; h3-js hands back `[lat, lng]` pairs. */
function toPolygon(h3: string): { lat: number; lng: number }[] {
  return hexBoundary(h3).map(([lat, lng]) => ({ lat, lng }));
}

/**
 * `GET /territory/hexes` fallback: the real cells covering the bbox, with
 * deterministic invented ownership — the VENUE cell is yours, every third cell is
 * open, the rest rotate through the rival handles. Power is a stable function of
 * the cell's position so the same bbox always renders identically (a fallback that
 * flickered between calls would be worse than no fallback).
 */
export function stubHexes(swLat: number, swLng: number, neLat: number, neLng: number): {
  h3: string;
  polygon: { lat: number; lng: number }[];
  ownerHandle: string | null;
  ownerColor: "mine" | "rival" | "unclaimed";
  power: number;
  yours: boolean;
}[] {
  const cells = cellsCoveringBBox(swLat, swLng, neLat, neLng);
  return cells.map((h3, i) => {
    const yours = h3 === VENUE.hexH3;
    const open = !yours && i % 3 === 0;
    const ownerHandle = yours ? null : open ? null : RIVALS[i % RIVALS.length];
    const ownerColor = yours ? "mine" : ownerHandle === null ? "unclaimed" : "rival";
    return {
      h3,
      polygon: toPolygon(h3),
      ownerHandle,
      ownerColor,
      power: 180 + ((i * 53) % 900),
      yours,
    };
  });
}

export interface StubHexDetail {
  h3: string;
  ownerHandle: string | null;
  power: number;
  yourPower: number;
  spots: unknown[];
  recentFlips: { handle: string; atMs: number }[];
}

/**
 * `GET /territory/hex/:h3` fallback: one contested hex (total power 1240, your
 * share 620) with two flips — the contract's "contested hex with two flips" stub.
 * `spots` is empty: spots are B-12 and out of scope, so fabricating one here would
 * assert a feature that does not exist (the same rule `consequences.ts` follows).
 * Timestamps are fixed rather than `Date.now()` so the fallback is deterministic.
 */
export function stubHexDetail(h3: string): StubHexDetail {
  const day = 86_400_000;
  return {
    h3,
    ownerHandle: RIVALS[0],
    power: 1240,
    yourPower: 620,
    spots: [],
    recentFlips: [
      { handle: RIVALS[0], atMs: 1_788_700_000_000 },
      { handle: "demo_athlete", atMs: 1_788_700_000_000 - day },
    ],
  };
}

export interface StubLeaderboardRow {
  rank: number;
  handle: string;
  hexesHeld: number;
  areaKm2: number;
}

/** `GET /territory/leaderboard` fallback: the seeded 10-row board, demo user 4th. */
export function stubLeaderboard(): StubLeaderboardRow[] {
  const rows: [string, number, number][] = [
    ["iron_meridian", 9, 6.7],
    ["rival_kat", 7, 5.2],
    ["parkside_crew", 6, 4.5],
    ["demo_athlete", 5, 3.7],
    ["north_bar_owl", 4, 3.0],
    ["plank_pilgrim", 3, 2.2],
    ["dip_machine", 3, 2.2],
    ["muscle_up_mo", 2, 1.5],
    ["sunrise_squat", 1, 0.7],
    ["slow_burn", 1, 0.7],
  ];
  return rows.map(([handle, hexesHeld, areaKm2], i) => ({
    rank: i + 1,
    handle,
    hexesHeld,
    areaKm2,
  }));
}
