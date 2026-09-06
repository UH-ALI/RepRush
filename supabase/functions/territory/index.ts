/// GET /territory/* — the map, the hex detail sheet and the board (B-9, B-10;
/// D1–D3, D6, D7).
///
/// ONE DEPLOYED FUNCTION, THREE REGISTER ROUTES, PATH DISPATCH. roles.md B-9/B-10
/// name separate `functions/territory/` and `functions/hexes/` directories, but
/// Supabase deploys one directory per function and Kong routes on that name; the
/// established pattern in this repo is one deployed function per endpoint AREA
/// (`session-start`, `session-submit`, `movements`). So the three register routes
/// —
///     GET territory/hexes?bbox=swLat,swLng,neLat,neLng   (B-10 map grid)
///     GET territory/hex/<h3>                              (D6 detail + flips)
///     GET territory/leaderboard                           (D7 board)
/// — share this function and are dispatched on the path tail. B-10's server-side
/// polygon computation lives here too. Deviation recorded so the register and the
/// tree can be reconciled later.
///
/// LAZY DECAY ON READ (D3). Nothing here reads a stored power total — there is
/// none. Every cell's power is reconstructed from the append-only contributions
/// ledger by `_shared/territory.ts` at `Date.now()`, so opening the map twice an
/// hour apart shows decayed numbers with nothing having been written in between.
/// `hex_ownership` (the materialised cache) is read ONLY by the leaderboard, where
/// scanning-and-decaying the whole ledger on every board open would be too slow;
/// it is written only on the submit path (session-submit), never here.
///
/// BOARD ISOLATION (J7). The caller's board is derived from the authenticated
/// identity in `auth.ts`, never from a request field, and every ledger/cache read
/// is filtered by it.

import { type Authed, requireUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { boardFor } from "../_shared/demo.ts";
import { isLive } from "../_shared/env.ts";
import { cellsCoveringBBox, hexBoundary } from "../_shared/h3.ts";
import { error, ErrorCode, HttpError, json, preflight, respond } from "../_shared/responses.ts";
import {
  leaderboardRows,
  loadHandles,
  loadLiveContributions,
  recentFlips,
} from "../_shared/repo.ts";
import {
  minClaimPower,
  ownerColor,
  RES8_AREA_KM2,
  resolveHexPower,
  resolveOwner,
} from "../_shared/territory.ts";
import { stubHexDetail, stubHexes, stubLeaderboard } from "../_shared/stubs/territory.ts";

/** Half a degree per side: the largest bbox the map may ask for (assumption). */
const MAX_BBOX_DEGREES = 0.5;
/** Hard cap on cells served for one bbox, over which we call it too large. */
const MAX_CELLS = 1000;

interface HexCellOut {
  h3: string;
  polygon: { lat: number; lng: number }[];
  ownerHandle: string | null;
  ownerColor: "mine" | "rival" | "unclaimed";
  power: number;
  yours: boolean;
}

/** `bbox=swLat,swLng,neLat,neLng` → validated floats, or a 400 the client can name. */
function parseBbox(raw: string | null): [number, number, number, number] {
  if (raw === null) {
    throw new HttpError(
      ErrorCode.MALFORMED_REQUEST,
      400,
      "territory/hexes needs ?bbox=swLat,swLng,neLat,neLng.",
    );
  }
  const parts = raw.split(",").map((s) => Number(s.trim()));
  if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) {
    throw new HttpError(
      ErrorCode.MALFORMED_REQUEST,
      400,
      `bbox must be four finite numbers "swLat,swLng,neLat,neLng", got "${raw}".`,
    );
  }
  const [swLat, swLng, neLat, neLng] = parts as [number, number, number, number];
  if (neLat <= swLat || neLng <= swLng) {
    throw new HttpError(
      ErrorCode.MALFORMED_REQUEST,
      400,
      "bbox north-east corner must be strictly north and east of the south-west corner.",
    );
  }
  if (neLat - swLat > MAX_BBOX_DEGREES || neLng - swLng > MAX_BBOX_DEGREES) {
    throw new HttpError(
      ErrorCode.BBOX_TOO_LARGE,
      400,
      `bbox side exceeds ${MAX_BBOX_DEGREES}°. Zoom in; the map serves a neighbourhood, not a city.`,
    );
  }
  return [swLat, swLng, neLat, neLng];
}

/**
 * GET territory/hexes — the claimed cells covering the bbox.
 *
 * Resolves each cell live from the ledger (D3), keeps only cells with a holder at
 * or above the claim threshold, and OMITS the unclaimed ones: the client draws the
 * basemap beneath, so an unclaimed hex is simply "no polygon over it" rather than a
 * shape we ship with `ownerHandle: null` (the assumption recorded in the plan; the
 * `'unclaimed'` colour token exists for the stub grid, not the live wire).
 */
async function handleHexes(user: Authed, bboxRaw: string | null): Promise<HexCellOut[]> {
  const [swLat, swLng, neLat, neLng] = parseBbox(bboxRaw);
  const cells = cellsCoveringBBox(swLat, swLng, neLat, neLng);
  if (cells.length > MAX_CELLS) {
    throw new HttpError(
      ErrorCode.BBOX_TOO_LARGE,
      400,
      `bbox covers ${cells.length} cells; the cap is ${MAX_CELLS}. Zoom in.`,
    );
  }
  if (cells.length === 0) return [];

  const client = db();
  const board = boardFor(user.isDemo);
  const nowMs = Date.now();
  const threshold = minClaimPower();

  const contributions = await loadLiveContributions(client, cells, board);

  // Resolve every cell, keep the winners, and collect the distinct owner ids so a
  // bbox of many cells costs ONE profiles round trip for handles.
  const claimed: { h3: string; ownerId: string; power: number }[] = [];
  for (const h3 of cells) {
    const powers = resolveHexPower(contributions.get(h3) ?? [], nowMs);
    const owner = resolveOwner(powers, threshold);
    if (owner === null) continue; // Unclaimed (or decayed below threshold): omitted.
    claimed.push({ h3, ownerId: owner.userId, power: owner.power });
  }

  const handles = await loadHandles(client, [...new Set(claimed.map((c) => c.ownerId))]);

  return claimed.map((c) => {
    const yours = c.ownerId === user.userId;
    return {
      h3: c.h3,
      polygon: hexBoundary(c.h3).map(([lat, lng]) => ({ lat, lng })),
      ownerHandle: handles.get(c.ownerId) ?? null,
      ownerColor: ownerColor(yours, true),
      power: c.power,
      yours,
    };
  });
}

interface HexDetailOut {
  h3: string;
  ownerHandle: string | null;
  power: number;
  yourPower: number;
  spots: unknown[];
  recentFlips: { handle: string; atMs: number }[];
}

/**
 * GET territory/hex/<h3> — one cell's detail sheet: holder, total power, YOUR
 * decayed power in it, and the recent flips (D6). `spots` is `[]` until B-12; a
 * fabricated spot would assert a feature that does not exist (the same rule
 * `consequences.ts` follows).
 */
async function handleHexDetail(user: Authed, h3: string): Promise<HexDetailOut> {
  const client = db();
  const board = boardFor(user.isDemo);
  const nowMs = Date.now();
  const threshold = minClaimPower();

  const contributions = await loadLiveContributions(client, [h3], board);
  const rows = contributions.get(h3) ?? [];
  const powers = resolveHexPower(rows, nowMs);
  const owner = resolveOwner(powers, threshold);
  const yourPower = powers.get(user.userId) ?? 0;

  if (owner === null && rows.length === 0) {
    // No ledger history at all for this cell — nothing has ever been scored here,
    // which is a different answer from "contested but currently unclaimed".
    throw new HttpError(ErrorCode.UNKNOWN_HEX, 404, `No territory recorded for hex ${h3}.`);
  }

  const flips = await recentFlips(client, h3, board);
  const handles = owner === null
    ? new Map<string, string>()
    : await loadHandles(client, [owner.userId]);

  return {
    h3,
    ownerHandle: owner === null ? null : handles.get(owner.userId) ?? null,
    power: owner === null ? 0 : owner.power,
    yourPower,
    spots: [],
    recentFlips: flips.map((f) => ({ handle: f.handle, atMs: f.atMs })),
  };
}

interface LeaderboardRowOut {
  rank: number;
  handle: string;
  hexesHeld: number;
  areaKm2: number;
}

/**
 * GET territory/leaderboard — holders ranked by hexes held (D7). Reads the
 * materialised `hex_ownership` cache, not the ledger: counting cache rows is
 * O(claimed hexes) with no decay maths, which is the entire reason the cache exists
 * (0007 header). `areaKm2 = hexesHeld × RES8_AREA_KM2`.
 */
async function handleLeaderboard(user: Authed): Promise<LeaderboardRowOut[]> {
  const client = db();
  const board = boardFor(user.isDemo);
  const rows = await leaderboardRows(client, board);
  return rows.map((row, i) => ({
    rank: i + 1,
    handle: row.handle,
    hexesHeld: row.hexesHeld,
    areaKm2: row.hexesHeld * RES8_AREA_KM2,
  }));
}

/** The path tail after the `territory` function name: ["hexes"], ["hex", h3], ["leaderboard"]. */
function routeParts(pathname: string): string[] {
  const parts = pathname.split("/").filter((s) => s.length > 0);
  const idx = parts.indexOf("territory");
  return idx >= 0 ? parts.slice(idx + 1) : parts;
}

// Not async: dispatches only, `respond` returns the promise (see movements/index.ts).
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    if (req.method !== "GET") {
      return error(ErrorCode.MALFORMED_REQUEST, "territory is GET only.", 405);
    }
    const user = await requireUser(req);

    const url = new URL(req.url);
    const route = routeParts(url.pathname);
    const [head, arg] = route;

    // Deploy-safety gate (docs/backend-scaffolding.md §6): before `territory` is in
    // LIVE_ENDPOINTS the route answers realistic canned JSON for the same path, so a
    // rollback on demo day is a flag flip, not a redeploy.
    if (!isLive("territory")) {
      if (head === "hexes") {
        const [swLat, swLng, neLat, neLng] = parseBbox(url.searchParams.get("bbox"));
        return json(stubHexes(swLat, swLng, neLat, neLng));
      }
      if (head === "hex" && arg !== undefined) return json(stubHexDetail(arg));
      if (head === "leaderboard") return json(stubLeaderboard());
      return error(
        ErrorCode.MALFORMED_REQUEST,
        `Unknown territory route: /${route.join("/")}.`,
        404,
      );
    }

    if (head === "hexes") return json(await handleHexes(user, url.searchParams.get("bbox")));
    if (head === "hex" && arg !== undefined) return json(await handleHexDetail(user, arg));
    if (head === "leaderboard") return json(await handleLeaderboard(user));

    return error(ErrorCode.MALFORMED_REQUEST, `Unknown territory route: /${route.join("/")}.`, 404);
  });
});
