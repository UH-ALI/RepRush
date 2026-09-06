/// Mint a real user JWT against a running local Supabase stack.
///
/// WHY THIS EXISTS
/// Every endpoint calls `requireUser`, which round-trips the bearer token through
/// `auth.getUser`. An anon key is not a user and gets a 401, so nothing on the
/// live path can be exercised without a token — and `supabase db ...` does not
/// issue one. Before this tool the only ways to get one were signing into the
/// Flutter app or hand-crafting a signup request, which is why the live submit
/// path went unexercised for as long as it did.
///
/// WHAT IT DOES
/// Signs in with a password grant, falling back to signup when the account does
/// not exist yet (local stacks auto-confirm, so signup returns a session
/// immediately). Then writes everything `submit_fixture.ts` needs to
/// `supabase/.temp/dev-env.json`, which is gitignored.
///
/// USAGE
///     node tool/dev_user.ts                       # stable default dev account
///     node tool/dev_user.ts --email me@x.dev      # a specific account
///     deno run --allow-net --allow-env --allow-write tool/dev_user.ts
///
/// The anon key comes from `npx supabase status` ("Publishable" on newer stacks,
/// anon JWT on older ones) or from the running container:
///     docker exec supabase_edge_runtime_<project> printenv SUPABASE_ANON_KEY

import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

// Written against `globalThis` rather than naming either runtime, the same way
// `_shared/env.ts` and `submit_fixture.ts` do it, so one file runs under `node`
// and `deno run`.
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
 * A stable default rather than a fresh account per run: repeated runs then reuse
 * one user, so lifetime score and the daily session budget accumulate the way
 * they would for a real athlete. Burn through the 20-per-day budget and pass a
 * different `--email` for a clean slate.
 */
const DEFAULT_EMAIL = "dev@reprush.local";
const DEFAULT_PASSWORD = "local-dev-only-123";

interface Options {
  base: string;
  anon: string;
  email: string;
  password: string;
}

function parseOptions(args: string[]): Options {
  let base = (envOf("SUPABASE_URL") ?? DEFAULT_BASE).replace(/\/$/, "");
  let anon = envOf("SUPABASE_ANON_KEY") ?? null;
  let email = envOf("REPRUSH_EMAIL") ?? DEFAULT_EMAIL;
  let password = envOf("REPRUSH_PASSWORD") ?? DEFAULT_PASSWORD;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = (what: string): string => {
      const value = args[++i];
      if (value === undefined) fail(`--${what} needs a value`);
      return value;
    };
    if (arg === "--base") base = next("base").replace(/\/$/, "");
    else if (arg === "--anon") anon = next("anon");
    else if (arg === "--email") email = next("email");
    else if (arg === "--password") password = next("password");
    else if (arg === "--help" || arg === "-h") usage();
    else if (arg.startsWith("--")) fail(`unknown option '${arg}' — try --help`);
    else fail(`unexpected argument '${arg}' — this tool takes options only`);
  }

  // `fail` returns `never`, so past this point `anon` is narrowed to `string` and
  // no call site needs a non-null assertion.
  if (anon === null) {
    fail(
      "no anon key. Pass --anon, or set SUPABASE_ANON_KEY. Get it from " +
        "`npx supabase status`, or:\n" +
        "  docker exec supabase_edge_runtime_<project> printenv SUPABASE_ANON_KEY",
    );
  }
  return { base, anon, email, password };
}

function usage(): never {
  console.log(`
dev_user.ts — mint a real user JWT from a running local Supabase stack

    node tool/dev_user.ts [options]

Options
    --base <url>       Stack URL. Default: $SUPABASE_URL or ${DEFAULT_BASE}
    --anon <key>       Anon/publishable key. Default: $SUPABASE_ANON_KEY
    --email <addr>     Default: $REPRUSH_EMAIL or ${DEFAULT_EMAIL}
    --password <pw>    Default: $REPRUSH_PASSWORD or ${DEFAULT_PASSWORD}
    --help             This text.

Writes supabase/.temp/dev-env.json (gitignored) and prints the values
submit_fixture.ts needs as SUPABASE_URL / SUPABASE_ANON_KEY / REPRUSH_TOKEN.
`);
  throw new HelpRequested();
}

interface AuthResponse {
  access_token?: string;
  refresh_token?: string;
  user?: { id?: string };
  id?: string;
  msg?: string;
  error?: string;
  error_description?: string;
}

async function postJson(url: string, anon: string, body: unknown): Promise<AuthResponse> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: anon },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  try {
    return JSON.parse(text) as AuthResponse;
  } catch {
    // A non-JSON body means something other than GoTrue answered — usually the
    // wrong port, or a stack that is still starting. Say so rather than throwing
    // a parse error at the reader.
    return fail(
      `${url} returned ${response.status} with a non-JSON body: ${text.slice(0, 160)}`,
    );
  }
}

async function main(): Promise<void> {
  const opts = parseOptions(argv());

  // Sign in first: it is the common case after the first run, and it keeps one
  // account accumulating history instead of leaving a trail of throwaway users.
  const signin = await postJson(`${opts.base}/auth/v1/token?grant_type=password`, opts.anon, {
    email: opts.email,
    password: opts.password,
  });

  let token = signin.access_token ?? null;
  let userId = signin.user?.id ?? signin.id ?? null;
  let how = "signed in";

  if (token === null) {
    const signup = await postJson(`${opts.base}/auth/v1/signup`, opts.anon, {
      email: opts.email,
      password: opts.password,
    });
    token = signup.access_token ?? null;
    userId = signup.user?.id ?? signup.id ?? null;
    how = "signed up";
    if (token === null) {
      fail(
        `neither sign-in nor sign-up produced a token.\n` +
          `  sign-in: ${signin.error ?? signin.msg ?? "no error field"}\n` +
          `  sign-up: ${signup.error ?? signup.msg ?? "no error field"}\n` +
          `Check that the stack is running (npx supabase status) and that email ` +
          `sign-up is enabled in supabase/config.toml.`,
      );
    }
  }

  const out = {
    base: opts.base,
    functionsBase: `${opts.base}/functions/v1`,
    anonKey: opts.anon,
    token,
    userId,
    email: opts.email,
  };

  const target = fileURLToPath(new URL("../supabase/.temp/dev-env.json", import.meta.url));
  mkdirSync(fileURLToPath(new URL("../supabase/.temp/", import.meta.url)), { recursive: true });
  writeFileSync(target, `${JSON.stringify(out, null, 2)}\n`);

  console.log(`${how} ${opts.email}`);
  console.log(`  user   ${userId}`);
  console.log(`  wrote  supabase/.temp/dev-env.json\n`);
  console.log("To drive submit_fixture.ts from this shell:");
  console.log(`  $env:SUPABASE_URL = "${opts.base}"`);
  console.log(
    `  $env:SUPABASE_ANON_KEY = (Get-Content supabase/.temp/dev-env.json -Raw | ConvertFrom-Json).anonKey`,
  );
  console.log(
    `  $env:REPRUSH_TOKEN = (Get-Content supabase/.temp/dev-env.json -Raw | ConvertFrom-Json).token`,
  );
  console.log("\nTo give this account demo context (J7), add to supabase/functions/.env:");
  console.log(`  DEMO_ACCOUNT_IDS=${userId}`);
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
