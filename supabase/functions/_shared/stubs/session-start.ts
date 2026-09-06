/// The canned `POST /session/start` response (docs/backend-scaffolding.md §6).
///
/// A stub here is not a client-side fake: it is the real function, at the real
/// URL, behind real auth, returning this. C wires up the URL, the bearer header
/// and `SessionStart.fromJson` against it on Day 1, so flipping `LIVE_ENDPOINTS`
/// on Day 3 is a data-source change and not a client rewrite.
///
/// Everything except `sessionId` and `hexH3` is real: the timestamp is the
/// current clock and the expiry is the same 4 h constant the live path uses (I2),
/// so a client that gets its window arithmetic wrong against the stub will also
/// get it wrong against the live route.

import { SESSION_EXPIRY_MS } from "../validation/session.ts";
import { VENUE } from "./venue.ts";

export interface SessionStartResponse {
  sessionId: string;
  serverStartMs: number;
  movementConfigVersion: string;
  hexH3: string;
  spotId: string | null;
  expiresAtMs: number;
}

export function stubStart(nowMs: number = Date.now()): SessionStartResponse {
  return {
    sessionId: VENUE.sessionId,
    serverStartMs: nowMs,
    movementConfigVersion: VENUE.movementConfigVersion,
    hexH3: VENUE.hexH3,
    spotId: VENUE.spotId,
    expiresAtMs: nowMs + SESSION_EXPIRY_MS,
  };
}
