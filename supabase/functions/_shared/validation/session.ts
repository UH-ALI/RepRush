/// Session gates — Class 1 validation. These HARD-REJECT with a 4xx, unlike the
/// shadow flags in `_shared/flags.ts`, and the distinction is the whole design:
///
///   Class 1 (here)   correctness. A submission that fails one of these cannot be
///                    scored at all — there is no session to attribute it to, no
///                    threshold version to score it against, or its claimed
///                    timeline did not happen inside the observed window.
///   Class 2 (flags)  judgement. A submission that trips one of these might still
///                    be an honest set from a shaky camera, so it is scored,
///                    flagged, and left for a human (I13).
///
/// Pure: the caller loads the session row and passes it in, so every gate is
/// unit-testable without a database.

import type { Evidence } from "../evidence/schema.ts";
import { HttpError } from "../responses.ts";
import { CONTEXT_MATCH_RADIUS_M, haversineM, impliedTravel, MAX_GPS_ACCURACY_M } from "./geo.ts";
import { checkWallClock } from "./wallclock.ts";

/**
 * Raised for a failed gate. `code` is one of the contract's stable strings.
 *
 * Extends [HttpError] so the route wrapper maps it with no per-error-class
 * boilerplate; the subclass exists only to give gate failures a name in logs.
 */
export class GateError extends HttpError {
  constructor(code: string, status: number, message: string) {
    super(code, status, message);
    this.name = "GateError";
  }
}

/** I2 — unsubmitted sessions expire after 4 h. */
export const SESSION_EXPIRY_MS = 4 * 60 * 60 * 1000;

/** The `workout_sessions` row as the gate needs it. */
export interface SessionRow {
  id: string;
  user_id: string;
  status: "open" | "submitted" | "expired" | "voided";
  movement_config_version: string;
  server_start_ms: number;
  submitted_at_ms: number | null;
  expires_at_ms: number;
  start_lat: number;
  start_lng: number;
  start_accuracy_m: number;
  start_is_mocked: boolean;
  start_h3: string;
  spot_id: string | null;
  board: "production" | "demo";
}

/** UTC calendar day, as the `daily_counters.day` key (I11). */
export function utcDay(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 10);
}

/** The `location` block of a `POST /session/start` request. */
export interface StartLocation {
  lat: number;
  lng: number;
  accuracyM: number;
  isMocked: boolean;
}

/**
 * Reads the start request. Deliberately not part of `evidence/schema.ts`: that
 * file describes the Evidence wire format and nothing else, and mixing a second
 * request shape into it would make "what does the parser accept" unanswerable by
 * reading one file.
 *
 * `isMocked` defaults to false rather than being required. A client that omits it
 * is not claiming a spoofed fix, and making the field mandatory would turn an
 * older build's request into a hard failure for no security gain — the gate below
 * is what decides whether the value is acceptable.
 */
export function parseStartRequest(raw: unknown): {
  location: StartLocation;
  spotId: string | null;
} {
  if (typeof raw !== "object" || raw === null) {
    throw new GateError("MALFORMED_REQUEST", 400, "Expected a JSON object.");
  }
  const body = raw as Record<string, unknown>;
  const loc = body["location"];
  if (typeof loc !== "object" || loc === null) {
    throw new GateError("MALFORMED_REQUEST", 400, "Missing 'location' object.");
  }
  const l = loc as Record<string, unknown>;

  const location: StartLocation = {
    lat: finite(l["lat"], "location.lat"),
    lng: finite(l["lng"], "location.lng"),
    accuracyM: finite(l["accuracyM"], "location.accuracyM"),
    isMocked: l["isMocked"] === true,
  };

  const spot = body["spotId"];
  const spotId = spot === undefined || spot === null
    ? null
    : typeof spot === "string" && spot.length > 0
    ? spot
    : bad("spotId", "expected a non-empty string or null");

  return { location, spotId };
}

function finite(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return bad(field, "expected a finite number");
  }
  return value;
}

function bad(field: string, why: string): never {
  throw new GateError("MALFORMED_REQUEST", 400, `'${field}': ${why}.`);
}

/**
 * The `POST /session/start` gates. Runs before anything is issued, so a rejected
 * start writes no row.
 *
 * Demo accounts (J7) are handled by the CALLER, not here: it substitutes the
 * fixed server-authorized location before calling, so this function never sees a
 * mocked coordinate from an allowlisted account and cannot be talked into
 * accepting one.
 */
export function checkStartGates(
  location: StartLocation,
  isDemoAccount: boolean,
  previous: { lat: number; lng: number; atMs: number } | null,
  nowMs: number,
): void {
  // Range before plausibility: h3-js throws rather than wraps on an out-of-range
  // coordinate, and a NaN from a malformed fix would otherwise reach haversine
  // first and produce a nonsense distance instead of a clear error.
  if (location.lat < -90 || location.lat > 90 || location.lng < -180 || location.lng > 180) {
    throw new GateError(
      "MALFORMED_REQUEST",
      400,
      `Coordinate out of range: ${location.lat}, ${location.lng}.`,
    );
  }
  if (location.isMocked && !isDemoAccount) {
    throw new GateError(
      "MOCKED_LOCATION_REJECTED",
      400,
      "Mocked location rejected for production accounts. Demo context is decided " +
        "server-side from an allowlisted account (J7) — no request field can ask for it.",
    );
  }
  if (location.accuracyM > MAX_GPS_ACCURACY_M) {
    throw new GateError(
      "GPS_TOO_INACCURATE",
      400,
      `GPS accuracy ${location.accuracyM.toFixed(0)} m exceeds the ${MAX_GPS_ACCURACY_M} m gate ` +
        "(D4). Move somewhere with a better sky view and try again.",
    );
  }
  if (previous !== null) {
    const travel = impliedTravel(
      previous.lat,
      previous.lng,
      location.lat,
      location.lng,
      nowMs - previous.atMs,
    );
    if (!travel.ok) {
      throw new GateError(
        "IMPLAUSIBLE_TRAVEL",
        400,
        `Implied travel of ${travel.distanceM.toFixed(0)} m in ` +
          `${Math.round(travel.elapsedMs / 1000)} s since the last session (I7).`,
      );
    }
  }
}

/**
 * The `POST /session/submit` gates, in the order they must run.
 *
 * Order matters: existence and ownership first (so nothing else can be probed
 * without a valid session), then the cheap string comparisons, then the geometric
 * ones, then wall-clock last — it needs the submit stamp, which the caller takes
 * immediately before calling.
 *
 * A session that exists but belongs to someone else reports UNKNOWN_SESSION, not
 * a distinct ownership error: an attacker must not be able to use the response to
 * discover which UUIDs are live.
 */
export function checkSubmitGates(
  row: SessionRow | null,
  evidence: Evidence,
  userId: string,
  nowMs: number,
): void {
  if (row === null || row.user_id !== userId) {
    throw new GateError(
      "UNKNOWN_SESSION",
      404,
      `No open session '${evidence.sessionId}' for this account.`,
    );
  }

  if (row.status === "submitted" || row.status === "voided") {
    // I2 — one-shot. "A second submission against the same id — verbatim or
    // edited — is rejected."
    throw new GateError(
      "SESSION_ALREADY_USED",
      409,
      `Session '${row.id}' was already consumed. Sessions are one-shot; start a new one.`,
    );
  }
  if (row.status === "expired") {
    throw new GateError("SESSION_EXPIRED", 410, `Session '${row.id}' expired unsubmitted.`);
  }
  if (nowMs > row.expires_at_ms) {
    throw new GateError(
      "SESSION_EXPIRED",
      410,
      `Session '${row.id}' passed its 4 h window (I2). Start a new one.`,
    );
  }

  if (evidence.sessionId !== row.id) {
    throw new GateError(
      "UNKNOWN_SESSION",
      404,
      "Evidence sessionId does not match the session being submitted.",
    );
  }

  // Clients cannot select an older configuration version — the server always
  // issues the current one and binds it here.
  if (evidence.movementConfigVersion !== row.movement_config_version) {
    throw new GateError(
      "CONFIG_VERSION_MISMATCH",
      409,
      `Evidence was captured against '${evidence.movementConfigVersion}' but the ` +
        `session is bound to '${row.movement_config_version}'. Thresholds are not ` +
        "comparable across versions, so the set cannot be scored.",
    );
  }

  // Defence in depth: mocked GPS was already refused at start, but the Evidence
  // carries its own location block and a production-board session must never
  // score one.
  if (evidence.location.isMocked && row.board === "production") {
    throw new GateError(
      "MOCKED_LOCATION_REJECTED",
      400,
      "Mocked location in Evidence against a production session (I7).",
    );
  }

  // Session context is deterministic: territory always resolves from the
  // server-recorded start context, never from the submitted location.
  if (!sameSpot(evidence.spotId, row.spot_id)) {
    throw new GateError(
      "SESSION_CONTEXT_MISMATCH",
      409,
      `Session opened at spot '${row.spot_id ?? "none"}' but Evidence claims ` +
        `'${evidence.spotId ?? "none"}'.`,
    );
  }
  const driftM = haversineM(
    row.start_lat,
    row.start_lng,
    evidence.location.lat,
    evidence.location.lng,
  );
  if (driftM > CONTEXT_MATCH_RADIUS_M) {
    throw new GateError(
      "SESSION_CONTEXT_MISMATCH",
      409,
      `Evidence location is ${driftM.toFixed(0)} m from the session-start fix ` +
        `(limit ${CONTEXT_MATCH_RADIUS_M} m).`,
    );
  }

  // I3 — last, because it needs the stamp the caller took on arrival.
  const clock = checkWallClock(evidence.sets, row.server_start_ms, nowMs);
  if (!clock.ok) {
    throw new GateError(
      "TIMELINE_OUT_OF_WINDOW",
      400,
      `Claimed timeline does not fit the server-observed window: ${clock.reason} (I3).`,
    );
  }
}

function sameSpot(a: string | null, b: string | null): boolean {
  return (a ?? null) === (b ?? null);
}
