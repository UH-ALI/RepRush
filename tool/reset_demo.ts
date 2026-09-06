/// Wipe one user's (or every user's) session-derived data from a local stack.
///
/// WHY THIS EXISTS
/// Test submits pile up against the dev account: lifetime score climbs, the daily
/// session budget burns toward the 20-per-day cap, and hex contributions accrete
/// until the map is noise. Before territory could be demoed from a clean board, or
/// a scoring fixture re-run against a known-zero lifetime, there was no way to
/// reset without dropping the whole database (and the minted account with it).
///
/// WHAT IT DOES — AND WHAT IT NEVER TOUCHES
/// Calls `reset_user_data(p_user)` / `reset_all_data()` (migration 0006) through
/// the service-role REST RPC. Those delete the SESSION-DERIVED rows only —
/// workout_sessions (cascading set_records → rep_events/pose_traces), score_ledger,
/// session_flags, daily_counters, devices, and the hex_* territory rows — and leave
/// `profiles`, `unlocked_movements`, `movements` and the config tables alone, so the
/// persisted anonymous/dev account keeps working after a reset.
///
/// THIS IS LOCAL-DEV / DEMO HYGIENE, NOT A PRODUCTION TOOL. The production
/// correction path for a bad session is `void_session()` (0004, I12), which
/// preserves the audit trail. A hard delete is right for wiping a rehearsal; it
/// would be wrong for correcting a real athlete's history.
///
/// USAGE
///     node tool/reset_demo.ts                         # the dev-env.json account
///     node tool/reset_demo.ts --email rival@reprush.local
///     node tool/reset_demo.ts --user <uuid>
///     node tool/reset_demo.ts --all --yes             # EVERY user (needs --yes)
///     deno run --allow-net --allow-env --allow-read tool/reset_demo.ts
///
/// The service key comes from `npx supabase status` ("Secret" on newer stacks) or:
///     docker exec supabase_edge_runtime_<project> printenv SUPABASE_SERVICE_ROLE_KEY

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Written against `globalThis` rather than naming either runtime, the same way
// `_shared/env.ts`, `dev_user.ts` and `submit_fixture.ts` do it, so one file runs
// under `node` and `deno run`.
const runtime = globalThis as {
  Deno?: { args: string[]; env: { get(name: string): string | undefined } };
  process?: { argv: string[]; env: Record<string, string | undefined> };
};

function argv(): string[] {
  return runtime.Deno?.args ?? runtime.process?.argv.slice(2) ?? [];
}

function envOf(name: string): string | undefined {
  const value = runtime.Deno?.env.get(name) ?? runtime.process?.env[name];
  return value === undefined || value.length === 0 ? undefined : value;
}

function fail(message: string): never {
  console.error(`\n${message}\n`);
  throw new Error(message);
}

class HelpRequested extends Error {
  constructor() {
    super("--help");
    this.name = "HelpRequested";
  }
}

/** The local stack's default gateway port. Overridable for a preview branch. */
const DEFAULT_BASE = "http://127.0.0.1:54321";

/**
 * `tool/dev_user.ts` writes the account it minted to `supabase/.temp/dev-env.json`.
 * Reading back `base` and `userId` is what makes the default target "the account
 * you have been submitting against" with no copy-paste. A missing or unreadable
 * file yields `{}`, so the caller still reports the target it is actually missing.
 */
function devEnv(): { base?: string; userId?: string } {
  try {
    const path = fileURLToPath(new URL("../supabase/.temp/dev-env.json", import.meta.url));
    return JSON.parse(readFileSync(path, "utf8")) as { base?: string; userId?: string };
  } catch {
    return {};
  }
}

interface Options {
  base: string;
  serviceKey: string;
  user: string | null;
  email: string | null;
  all: boolean;
  yes: boolean;
}

function parseOptions(args: string[]): Options {
  const dev = devEnv();
  let base = (envOf("SUPABASE_URL") ?? dev.base ?? DEFAULT_BASE).replace(/\/$/, "");
  let serviceKey = envOf("SUPABASE_SERVICE_ROLE_KEY") ?? null;
  let user: string | null = null;
  let email: string | null = null;
  let all = false;
  let yes = false;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = (what: string): string => {
      const value = args[++i];
      if (value === undefined) fail(`--${what} needs a value`);
      return value;
    };
    if (arg === "--base") base = next("base").replace(/\/$/, "");
    else if (arg === "--service-key") serviceKey = next("service-key");
    else if (arg === "--user") user = next("user");
    else if (arg === "--email") email = next("email");
    else if (arg === "--all") all = true;
    else if (arg === "--yes" || arg === "-y") yes = true;
    else if (arg === "--help" || arg === "-h") usage();
    else if (arg.startsWith("--")) fail(`unknown option '${arg}' — try --help`);
    else fail(`unexpected argument '${arg}' — this tool takes options only`);
  }

  if (serviceKey === null) {
    fail(
      "no service-role key. Pass --service-key, or set SUPABASE_SERVICE_ROLE_KEY.\n" +
        'Get it from `npx supabase status` ("Secret"), or:\n' +
        "  docker exec supabase_edge_runtime_<project> printenv SUPABASE_SERVICE_ROLE_KEY",
    );
  }

  const targets = [user !== null, email !== null, all].filter(Boolean).length;
  if (targets === 0) {
    // Fall back to the dev-env account only when nothing was asked for explicitly.
    if (dev.userId === undefined) {
      fail(
        "no target. Pass --user <uuid>, --email <addr>, or --all.\n" +
          "(No supabase/.temp/dev-env.json to default to — run `deno task user` first.)",
      );
    }
    user = dev.userId;
  } else if (targets > 1) {
    fail("pick ONE of --user, --email, --all.");
  }

  if (all && !yes) {
    fail("--all wipes EVERY user's session-derived data. Re-run with --all --yes to confirm.");
  }

  return { base, serviceKey, user, email, all, yes };
}

function usage(): never {
  console.log(`
reset_demo.ts — wipe session-derived data from a local Supabase stack

    node tool/reset_demo.ts [options]

Options
    --base <url>          Stack URL. Default: $SUPABASE_URL, dev-env.json, or ${DEFAULT_BASE}
    --service-key <key>   Service-role key. Default: $SUPABASE_SERVICE_ROLE_KEY
    --user <uuid>         Reset one user by id.
    --email <addr>        Reset one user by email (resolved via the auth admin API).
    --all                 Reset EVERY user. Requires --yes.
    --yes, -y             Confirm --all.
    --help                This text.

Target default: the userId in supabase/.temp/dev-env.json (what "deno task user"
mints and "deno task submit" submits against).

Deletes workout_sessions (+ set_records/rep_events/pose_traces), score_ledger,
session_flags, daily_counters, devices and the hex_* territory rows. NEVER touches
profiles, unlocked_movements, movements or the config tables — the account survives.
This is demo hygiene; the production correction path is void_session() (I12).
`);
  throw new HelpRequested();
}

/** Resolves an email to a user id through the GoTrue admin API, with the service key. */
async function userIdForEmail(base: string, serviceKey: string, email: string): Promise<string> {
  const url = `${base}/auth/v1/admin/users?filter=${encodeURIComponent(email)}`;
  const response = await fetch(url, {
    headers: { apikey: serviceKey, authorization: `Bearer ${serviceKey}` },
  });
  const text = await response.text();
  if (!response.ok) {
    fail(`auth admin lookup returned ${response.status}: ${text.slice(0, 200)}`);
  }
  let users: { id?: string; email?: string }[];
  try {
    const parsed = JSON.parse(text) as { users?: { id?: string; email?: string }[] };
    users = parsed.users ?? [];
  } catch {
    fail(`auth admin lookup returned a non-JSON body: ${text.slice(0, 160)}`);
  }
  // `filter` is a substring match; require an exact email so a prefix cannot reset
  // the wrong account.
  const match = users.find((u) => u.email?.toLowerCase() === email.toLowerCase());
  if (match?.id === undefined) fail(`no user with email '${email}' on ${base}.`);
  return match.id;
}

/** Calls a `reset_*` RPC through the service-role REST endpoint and returns its summary. */
async function callRpc(
  base: string,
  serviceKey: string,
  fn: "reset_user_data" | "reset_all_data",
  body: Record<string, unknown>,
): Promise<unknown> {
  const response = await fetch(`${base}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: serviceKey,
      authorization: `Bearer ${serviceKey}`,
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  if (!response.ok) {
    fail(
      `${fn} returned ${response.status}: ${text.slice(0, 300)}\n` +
        `Is migration 0006 applied? (npx supabase migration up)`,
    );
  }
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function main(): Promise<void> {
  const opts = parseOptions(argv());

  if (opts.all) {
    const summary = await callRpc(opts.base, opts.serviceKey, "reset_all_data", {});
    console.log("Reset EVERY user's session-derived data on", opts.base);
    console.log(JSON.stringify(summary, null, 2));
    return;
  }

  const userId = opts.user ?? await userIdForEmail(opts.base, opts.serviceKey, opts.email!);
  const summary = await callRpc(opts.base, opts.serviceKey, "reset_user_data", { p_user: userId });
  console.log(`Reset user ${userId} on ${opts.base}`);
  console.log(JSON.stringify(summary, null, 2));
}

try {
  await main();
} catch (error) {
  if (error instanceof HelpRequested) {
    // --help is a successful exit.
  } else {
    throw error;
  }
}
