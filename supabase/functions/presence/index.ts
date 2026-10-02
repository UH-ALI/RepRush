/// POST /presence · POST /presence/off — opt-in visibility to nearby athletes.
///
/// One deployed function, two routes, dispatched on the path tail like
/// `challenges`. ALWAYS LIVE: there is no canned presence worth serving to a real
/// account — the client's stub repository is the stub-mode answer.
///
/// POST presence `{ location }` is the heartbeat. It resolves the fix to a res-8
/// cell, stores THE CELL ONLY (N7) and answers with the other athletes visible
/// within `NEARBY_RING_K` rings on the same board, each placed at their cell's
/// centre. Visibility is reciprocal by construction: the only way to read the
/// list is to beat, and beating makes you visible.
///
/// POST presence/off deletes your row so you vanish at once rather than at the
/// TTL. "off" is a POST because the functions' CORS allows GET and POST only.
///
/// Demo accounts (J7) are placed at the server's demo venue, never at their own
/// fix, and only ever see — and are seen by — the demo board.

import { type Authed, requireUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { boardFor, demoLocation } from "../_shared/demo.ts";
import { hexCentre, hexFor, hexRing } from "../_shared/h3.ts";
import { NEARBY_RING_K, PRESENCE_MAX_ACCURACY_M, PRESENCE_TTL_MS } from "../_shared/presence.ts";
import { deletePresence, playerStats, presenceIn, upsertPresence } from "../_shared/repo.ts";
import { error, ErrorCode, HttpError, json, preflight, respond } from "../_shared/responses.ts";
import { levelForXp } from "../_shared/stubs/consequences.ts";
import { parseStartRequest } from "../_shared/validation/session.ts";

interface NearbyPlayerOut {
  userId: string;
  handle: string;
  level: number;
  hexesHeld: number;
  h3: string;
  centre: { lat: number; lng: number };
}

async function handleHeartbeat(req: Request, user: Authed): Promise<NearbyPlayerOut[]> {
  const raw: unknown = await req.json().catch(() => null);
  const location = user.isDemo ? demoLocation() : parseStartRequest(raw).location;

  if (location.lat < -90 || location.lat > 90 || location.lng < -180 || location.lng > 180) {
    throw new HttpError(ErrorCode.MALFORMED_REQUEST, 400, "Coordinate out of range.");
  }
  // The same mock rule as session start (I7): a spoofed fix could put you in
  // anyone's hex and let you challenge them from across town.
  if (location.isMocked && !user.isDemo) {
    throw new HttpError(
      ErrorCode.MOCKED_LOCATION_REJECTED,
      400,
      "Mocked location rejected for production accounts.",
    );
  }
  if (location.accuracyM > PRESENCE_MAX_ACCURACY_M) {
    throw new HttpError(
      ErrorCode.GPS_TOO_INACCURATE,
      400,
      `GPS accuracy ${location.accuracyM.toFixed(0)} m exceeds the ` +
        `${PRESENCE_MAX_ACCURACY_M} m presence gate.`,
    );
  }

  const client = db();
  const board = boardFor(user.isDemo);
  const h3 = hexFor(location.lat, location.lng);
  await upsertPresence(client, { userId: user.userId, board, h3 });

  const nowMs = Date.now();
  const others = await presenceIn(
    client,
    board,
    hexRing(h3, NEARBY_RING_K),
    nowMs - PRESENCE_TTL_MS,
    user.userId,
  );
  const stats = await playerStats(client, others.map((p) => p.userId), board);
  return others.map((p) => {
    const s = stats.get(p.userId);
    return {
      userId: p.userId,
      handle: s?.handle ?? "athlete",
      level: levelForXp(s?.xp ?? 0),
      hexesHeld: s?.hexesHeld ?? 0,
      h3: p.h3,
      centre: hexCentre(p.h3),
    };
  });
}

/** The path tail after the `presence` function name: [] or ["off"]. */
function routeParts(pathname: string): string[] {
  const parts = pathname.split("/").filter((s) => s.length > 0);
  const idx = parts.indexOf("presence");
  return idx >= 0 ? parts.slice(idx + 1) : parts;
}

// Not async: dispatches only, `respond` returns the promise (see movements/index.ts).
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    const user = await requireUser(req);
    const route = routeParts(new URL(req.url).pathname).join("/");

    if (route === "" && req.method === "POST") return json(await handleHeartbeat(req, user));
    if (route === "off" && req.method === "POST") {
      await deletePresence(db(), user.userId);
      return json({ visible: false });
    }

    return error(
      ErrorCode.MALFORMED_REQUEST,
      `Unknown presence route: ${req.method} /${route}.`,
      404,
    );
  });
});
