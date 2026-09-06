/// Runtime configuration — env vars and the demo allowlist.
///
/// Split out of `db.ts` so it carries no `npm:` import and therefore loads under
/// plain Node. That matters because `isLive`, `parseList` and `demoAccountIds`
/// contain real parsing logic (comma splitting, trimming, allowlist membership)
/// that is worth unit-testing, and because `_shared/demo.ts` needs `envOr` without
/// dragging the Supabase client into the pure tree.

/** The slice of the Deno runtime this module needs. Typed locally, not imported. */
interface EnvSource {
  get(name: string): string | undefined;
}

/// Reaching the env through `globalThis` rather than naming `Deno` directly is
/// deliberate, not defensive noise: under Node `globalThis.Deno` is simply absent
/// and every read returns `undefined`, which is the correct answer for a config
/// key that is not set. The alternative — a Deno-only module — would make every
/// consumer untestable without the runtime.
function envSource(): EnvSource {
  const deno = (globalThis as { Deno?: { env?: EnvSource } }).Deno;
  return deno?.env ?? { get: () => undefined };
}

/**
 * A required env var. Fails loudly at first use rather than letting an undefined
 * key reach `createClient` and surface later as an opaque 401.
 */
export function env(name: string): string {
  const value = envSource().get(name);
  if (value === undefined || value.length === 0) {
    throw new Error(`missing required environment variable ${name}`);
  }
  return value;
}

/** An optional env var with a default. */
export function envOr(name: string, fallback: string): string {
  const value = envSource().get(name);
  return value === undefined || value.length === 0 ? fallback : value;
}

/** An optional env var that may legitimately be absent. */
export function envMaybe(name: string): string | null {
  const value = envSource().get(name);
  return value === undefined || value.length === 0 ? null : value;
}

/** Comma-separated env value → trimmed, non-empty entries. */
export function parseList(raw: string | undefined): string[] {
  return (raw ?? "").split(",").map((s) => s.trim()).filter((s) => s.length > 0);
}

/**
 * True when a route should run its real handler rather than return canned JSON
 * (docs/backend-scaffolding.md §6). Endpoints go live one at a time by flipping
 * `LIVE_ENDPOINTS`, so a regression on demo day is a per-route rollback in
 * seconds rather than a redeploy.
 */
export function isLive(route: string): boolean {
  return parseList(envSource().get("LIVE_ENDPOINTS")).includes(route);
}

/** Comma-separated allowlist of demo account UUIDs (J7). Server-side only. */
export function demoAccountIds(): ReadonlySet<string> {
  return new Set(parseList(envSource().get("DEMO_ACCOUNT_IDS")));
}
