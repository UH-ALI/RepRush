/// HTTP plumbing shared by every route: the error envelope, CORS, and preflight.
///
/// Only web-standard `Response` — no Deno APIs — so this file also loads under
/// Node and the envelope can be asserted in tests.

import { EvidenceError } from "./evidence/schema.ts";
import { CatalogueError } from "./evidence/thresholds.ts";

/**
 * The stable machine-readable codes (api-contract.md §Common rules: "4xx
 * responses carry a stable machine-readable `code` plus a human `message`.
 * Unknown codes are a contract bug").
 *
 * These MUST stay in sync with `ApiErrorCode` in `lib/models/models.dart`. The
 * codes below the line are new relative to that file and were introduced by this
 * slice; each exists because a route has to say something the register did not
 * anticipate:
 *   UNKNOWN_SESSION     the register names the failure but models.dart lacked it
 *   EVIDENCE_MALFORMED  the §evidence payload did not parse, or names a movement
 *                       we do not have — either way it cannot be scored
 *   MALFORMED_REQUEST   a non-Evidence request body we cannot read
 *   RATE_LIMITED        I11 session-per-day budget exhausted
 *   SCORING_FAILED      a seeding gap made the payload unscorable (our bug)
 *   BBOX_TOO_LARGE      GET /territory/hexes asked for more map than we serve
 *   INTERNAL            an unhandled server fault; still needs a code
 */
export const ErrorCode = {
  UNAUTHENTICATED: "UNAUTHENTICATED",
  GPS_TOO_INACCURATE: "GPS_TOO_INACCURATE",
  IMPLAUSIBLE_TRAVEL: "IMPLAUSIBLE_TRAVEL",
  MOCKED_LOCATION_REJECTED: "MOCKED_LOCATION_REJECTED",
  SESSION_ALREADY_USED: "SESSION_ALREADY_USED",
  SESSION_EXPIRED: "SESSION_EXPIRED",
  TIMELINE_OUT_OF_WINDOW: "TIMELINE_OUT_OF_WINDOW",
  CONFIG_VERSION_MISMATCH: "CONFIG_VERSION_MISMATCH",
  SESSION_CONTEXT_MISMATCH: "SESSION_CONTEXT_MISMATCH",
  UNKNOWN_SESSION: "UNKNOWN_SESSION",
  EVIDENCE_MALFORMED: "EVIDENCE_MALFORMED",
  MALFORMED_REQUEST: "MALFORMED_REQUEST",
  RATE_LIMITED: "RATE_LIMITED",
  SCORING_FAILED: "SCORING_FAILED",
  BBOX_TOO_LARGE: "BBOX_TOO_LARGE",
  UNKNOWN_HEX: "UNKNOWN_HEX",
  INTERNAL: "INTERNAL",
} as const;

export type ErrorCodeValue = (typeof ErrorCode)[keyof typeof ErrorCode];

/**
 * Permissive by design. The only clients are our own Flutter app and curl during
 * development; auth is the bearer token, not the Origin header, so a tight CORS
 * allowlist would buy nothing and cost a debugging session on demo day.
 */
const CORS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-reprush-platform",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Access-Control-Max-Age": "86400",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json; charset=utf-8" },
  });
}

export function error(code: string, message: string, status: number): Response {
  return json({ code, message }, status);
}

/** Answers `OPTIONS`. Every route delegates here before anything else. */
export function preflight(): Response {
  return new Response("ok", { status: 200, headers: CORS });
}

/**
 * Extracts the bearer token. Returns null rather than throwing so the caller
 * decides between a 401 and an anonymous path.
 */
export function bearerToken(req: Request): string | null {
  const header = req.headers.get("authorization");
  if (header === null) return null;
  const [scheme, token] = header.split(" ");
  if (scheme === undefined || token === undefined) return null;
  if (scheme.toLowerCase() !== "bearer") return null;
  return token.length > 0 ? token : null;
}

/**
 * An error that knows its own HTTP status and contract code. Thrown by auth,
 * by the repo layer, and by the validators (`GateError` extends this).
 */
export class HttpError extends Error {
  readonly code: string;
  readonly status: number;

  // Explicit assignment, not a constructor parameter property: Node's default
  // strip-only TS mode rejects parameter properties, and this tree has to load
  // under plain Node for the fixture and golden suite.
  constructor(code: string, status: number, message: string) {
    super(message);
    this.name = "HttpError";
    this.code = code;
    this.status = status;
  }
}

/**
 * The single place a domain error becomes an HTTP response. Keeping the mapping
 * in one function is what makes the code table above auditable against
 * `ApiErrorCode` in models.dart — a new error class cannot silently escape as a
 * bare 500 without showing up here.
 */
export function toResponse(failure: unknown): Response {
  if (failure instanceof HttpError) {
    return error(failure.code, failure.message, failure.status);
  }
  if (failure instanceof EvidenceError) {
    // `pointer` is in the message already; it is the fastest way to find which
    // field of a 40 KB payload the client got wrong.
    return error(ErrorCode.EVIDENCE_MALFORMED, failure.message, 422);
  }
  if (failure instanceof CatalogueError) {
    // Codes describing the payload are the client's error; codes describing the
    // catalogue are ours. `CONFIG_MISSING_OFFSETS` means a movement was seeded
    // without thresholds, `CATALOGUE_MALFORMED` means a row we cannot read —
    // both are 500s and both should never happen after 0003.
    return failure.code === "UNKNOWN_MOVEMENT" || failure.code === "MEASUREMENT_TYPE_MISMATCH"
      ? error(ErrorCode.EVIDENCE_MALFORMED, failure.message, 422)
      : error(ErrorCode.SCORING_FAILED, failure.message, 500);
  }
  return error(ErrorCode.INTERNAL, "Internal error while processing the request.", 500);
}

/**
 * Wraps a route body so an uncaught throw still produces a well-formed envelope
 * rather than Deno's default 500 with an empty body — which the Flutter client
 * would fail to parse and surface as a mystery network error.
 */
export async function respond(run: () => Promise<Response>): Promise<Response> {
  try {
    return await run();
  } catch (failure) {
    // Logged, never echoed: the message goes to the server log and the client
    // gets the generic 500 above, so an internal detail cannot leak.
    console.error("route failure", failure);
    return toResponse(failure);
  }
}
