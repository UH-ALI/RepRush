/// Authentication for the Edge Functions.
///
/// `verify_jwt` is FALSE for every route in `supabase/config.toml`, and that is a
/// deliberate choice rather than an oversight. When the runtime verifies the JWT
/// it rejects a bad token with its own bare 401 — no CORS headers, no
/// `{ code, message }` body — which the Flutter client cannot parse and would
/// surface as an opaque network failure. Verifying here instead costs one call to
/// `auth.getUser` and buys the contract's error shape on every path, including
/// the unauthenticated one.
///
/// Deno-only: it needs the service-role client.

import { db } from "./db.ts";
import { demoAccountIds } from "./env.ts";
import { bearerToken, ErrorCode, HttpError } from "./responses.ts";

export interface Authed {
  userId: string;
  /**
   * True when the account is on the server-side demo allowlist (J7). Decided
   * here, from the authenticated identity and an env var — never from a request
   * field, so no client can ask for demo context or extend it.
   */
  isDemo: boolean;
}

/**
 * Resolves the bearer token to a user, or throws `401 UNAUTHENTICATED`.
 *
 * `auth.getUser` round-trips to the auth server rather than decoding the JWT
 * locally. That is one extra network hop per request and it is worth it: local
 * verification accepts a token the server has since revoked, and a revoked
 * account is exactly the one you do not want still scoring territory.
 */
export async function requireUser(req: Request): Promise<Authed> {
  const token = bearerToken(req);
  if (token === null) {
    throw new HttpError(
      ErrorCode.UNAUTHENTICATED,
      401,
      "Missing bearer token. Every endpoint requires a Supabase auth token; the " +
        "guest sign-in path issues one too.",
    );
  }

  const { data, error } = await db().auth.getUser(token);
  if (error !== null || data.user === null || data.user === undefined) {
    // The reason is logged and not echoed: "token expired" versus "user not
    // found" is useful to us and useful to an attacker probing tokens.
    console.warn("auth.getUser failed", error?.message ?? "no user");
    throw new HttpError(ErrorCode.UNAUTHENTICATED, 401, "Token rejected.");
  }

  const userId = data.user.id;
  return { userId, isDemo: demoAccountIds().has(userId) };
}

/**
 * The platform string for device binding (A3), read from a request header.
 *
 * A header and not a body field because it is transport metadata, not part of
 * Evidence — and because `POST /session/submit`'s body must stay the §evidence
 * object verbatim, since that is precisely what gets stored in
 * `workout_sessions.evidence` and replayed by the validators.
 */
export function clientPlatform(req: Request): string {
  const raw = req.headers.get("x-reprush-platform");
  if (raw === "android" || raw === "ios" || raw === "web" || raw === "windows") {
    return raw;
  }
  return "unknown";
}
