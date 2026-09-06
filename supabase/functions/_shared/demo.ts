/// Demo context (J7) — the one place a request's own claims about location are
/// overridden rather than checked.
///
/// The rule from api-contract.md §Common rules: "A server-authorized demo account
/// is permitted a **fixed demo location** — substituted server-side — and its
/// sessions/check-ins count only against the **isolated demo board**. No client
/// request field can request, extend, or force demo context."
///
/// Two properties make that hold, and both are enforced by the shape of this file:
///
///   1. Membership comes from `DEMO_ACCOUNT_IDS`, an env var matched against the
///      AUTHENTICATED identity in `auth.ts`. Nothing here reads the request body.
///   2. Substitution replaces the whole location object. It does not clamp,
///      correct, or validate what the client sent — a value that is discarded
///      cannot influence the result, which is stronger than any check on it.
///
/// A demo session is therefore indistinguishable from a real one to the scorer and
/// to every validator: same gates, same caps, same flags. Only the coordinate and
/// the board differ. That is deliberate — a demo path that skipped validation
/// would be the path nobody tests, and the path that breaks on stage.

import { envMaybe } from "./env.ts";
import { ErrorCode, HttpError } from "./responses.ts";
import type { StartLocation } from "./validation/session.ts";

export type Board = "production" | "demo";

/** Which board a session counts against. Decided from identity alone. */
export function boardFor(isDemo: boolean): Board {
  return isDemo ? "demo" : "production";
}

/**
 * The fixed demo coordinate, from `DEMO_LOCATION="lat,lng"`.
 *
 * `accuracyM` is a tight 5 m and `isMocked` is false: this is a server-authorized
 * value, not a client's spoofed fix, and reporting it as mocked would make
 * `checkStartGates` reject the very account the allowlist exists to permit.
 */
export function demoLocation(): StartLocation {
  const raw = envMaybe("DEMO_LOCATION");
  if (raw === null) {
    // A misconfiguration, not a client error, and not one to paper over with a
    // hardcoded default: a wrong venue coordinate silently puts every demo
    // session in the wrong hex, which is much harder to spot on stage than a 500.
    console.error("DEMO_LOCATION is not set but a demo account called session/start");
    throw new HttpError(
      ErrorCode.INTERNAL,
      500,
      "Demo context is not configured on this deployment.",
    );
  }
  const [latRaw, lngRaw] = raw.split(",");
  const lat = Number(latRaw);
  const lng = Number(lngRaw);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) {
    console.error(`DEMO_LOCATION is not "lat,lng": ${raw}`);
    throw new HttpError(
      ErrorCode.INTERNAL,
      500,
      "Demo context is misconfigured on this deployment.",
    );
  }
  return { lat, lng, accuracyM: 5, isMocked: false };
}

/**
 * The fixed demo spot, from `DEMO_SPOT_ID`. Null when unset, which is a legal
 * answer — a demo account can train in a hex without being at a spot.
 */
export function demoSpotId(): string | null {
  return envMaybe("DEMO_SPOT_ID");
}
