/// POST /session/start — open a one-shot session and fix its context (I2, I3).
///
/// What this route actually establishes, and why it cannot be delegated to the
/// client:
///
///   · the session id is server-generated, so no locally minted id is ever
///     accepted (api-contract.md §Session lifecycle)
///   · `server_start_ms` is the server's clock at arrival, which becomes one of
///     the only two trusted timestamps in the system — submit measures the entire
///     claimed rep timeline against this and its own arrival stamp (I3)
///   · `movement_config_version` is read from the active row and BOUND here, so a
///     client cannot later select a more forgiving threshold set
///   · the start fix is stored once. Territory always resolves from this row,
///     never from the location in the submitted Evidence, so moving during a
///     session cannot move the capture
///
/// Route order is deliberate: method → auth → live flag → gates → writes. The
/// gates run before any write, so a rejected start leaves no row and burns no
/// slot in the day's budget.

import { type Authed, clientPlatform, requireUser } from "../_shared/auth.ts";
import { db } from "../_shared/db.ts";
import { boardFor, demoLocation, demoSpotId } from "../_shared/demo.ts";
import { isLive } from "../_shared/env.ts";
import { hexFor } from "../_shared/h3.ts";
import { error, ErrorCode, json, preflight, respond } from "../_shared/responses.ts";
import {
  activeConfigVersion,
  bindDevice,
  claimSessionSlot,
  createSession,
  previousFix,
} from "../_shared/repo.ts";
import { type SessionStartResponse, stubStart } from "../_shared/stubs/session-start.ts";
import { checkStartGates, parseStartRequest, utcDay } from "../_shared/validation/session.ts";

async function handleStart(req: Request, user: Authed): Promise<SessionStartResponse> {
  const client = db();

  // Taken before parsing the body: this is the timestamp the session is timed
  // from, so it should reflect arrival rather than the moment we finished reading.
  const nowMs = Date.now();
  const day = utcDay(nowMs);

  const raw: unknown = await req.json().catch(() => null);
  const request = parseStartRequest(raw);

  // J7 — substitution, not permission. A demo account's own coordinate is
  // discarded wholesale and replaced with the server's fixed venue fix, so
  // nothing it sent can influence where the session lands. `checkStartGates`
  // then sees a clean, unmocked, accurate location and passes it on the merits.
  const location = user.isDemo ? demoLocation() : request.location;
  const spotId = user.isDemo ? demoSpotId() : request.spotId;

  // I7 — implied travel from the previous session. Read before the gates so the
  // gate function stays pure and testable with a literal `previous`.
  const previous = await previousFix(client, user.userId);
  checkStartGates(location, user.isDemo, previous, nowMs);

  // Everything below writes. Past this point a failure leaves a partial but
  // harmless state: a claimed slot with no session, or a bound device with no
  // session. Neither awards anything, and neither can be replayed.
  await claimSessionSlot(client, user.userId, day);
  await bindDevice(client, user.userId, clientPlatform(req));

  const version = await activeConfigVersion(client);
  const row = await createSession(client, {
    userId: user.userId,
    movementConfigVersion: version,
    serverStartMs: nowMs,
    lat: location.lat,
    lng: location.lng,
    accuracyM: location.accuracyM,
    isMocked: location.isMocked,
    h3: hexFor(location.lat, location.lng),
    spotId,
    board: boardFor(user.isDemo),
  });

  return {
    sessionId: row.id,
    serverStartMs: row.server_start_ms,
    movementConfigVersion: row.movement_config_version,
    hexH3: row.start_h3,
    spotId: row.spot_id,
    expiresAtMs: row.expires_at_ms,
  };
}

// Not async: this handler only dispatches, and `respond` already returns the
// promise. An `async` that never awaits is what require-await flags.
Deno.serve((req: Request): Response | Promise<Response> => {
  if (req.method === "OPTIONS") return preflight();
  return respond(async () => {
    if (req.method !== "POST") {
      return error(ErrorCode.MALFORMED_REQUEST, "session/start is POST only.", 405);
    }
    // Real auth even on the stub path — that is what makes the Day-3 swap a
    // data-source flip rather than a client rewrite (§6).
    const user = await requireUser(req);
    if (!isLive("session-start")) return json(stubStart());
    return json(await handleStart(req, user));
  });
});
