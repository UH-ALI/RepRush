/// Seed a demo board with rival territory, so the map has contest and a decay
/// gradient instead of one lone dev-user cell.
///
/// WHY THIS EXISTS
/// Territory reads are only interesting against competition: `GET /territory/hexes`
/// resolving a single uncontested cell cannot show a `rival` polygon, a contested
/// `hex/<h3>` detail (total power > yourPower), a flip, or a leaderboard with more
/// than one row. This tool creates that competition on demand, and `deno task reset
/// --all --yes` wipes it back to clean.
///
/// DENO-ONLY — no `seed:node` pair, and that is deliberate. Seeding real cells needs
/// `_shared/h3.ts` (`npm:h3-js`) to compute the res-8 ids and boundaries around the
/// venue; `npm:` specifiers do not resolve under plain Node, exactly as they do not
/// for `_shared/stubs/territory.ts` (see that file's header for the same call). The
/// dual-runtime `:node` pairs exist for the pure tree and the fixtures; this tool is
/// outside both. `deno task check/lint/fmt/test` already require Deno.
///
/// HOW IT SEEDS — AND WHY NOT A PLAIN `profiles` INSERT
/// `profiles.id` is a foreign key to `auth.users(id)`, and `on_auth_user_created`
/// (migration 0001) already creates a profile the instant an auth user exists. So a
/// rival cannot be inserted into `profiles` directly with a fixed UUID — the FK
/// rejects it and the trigger would race it. The correct path is: create the auth
/// user through the GoTrue ADMIN API (which fires the trigger and yields a real id),
/// then PATCH the generated `athlete_xxxxxx` handle to the rival handle. Likewise a
/// `hex_contributions` row is only visible through the `hex_contributions_live` view
/// when it references a `submitted` `workout_sessions` row, so each contribution is
/// seeded together with a backdated submitted session.
///
/// BOARD (J7). Contributions carry `board`; a rival only shows on the dev user's map
/// when both are on the SAME board, and the board is derived server-side from
/// `DEMO_ACCOUNT_IDS` membership. Default `--board demo` matches a dev account that
/// has been added to the demo allowlist; pass `--board production` for a plain one.
///
/// IDEMPOTENT. Rivals are keyed on a fixed email (looked up before create), sessions
/// and contributions on fixed UUIDs, upserted with `resolution=merge-duplicates`.
/// Re-running refreshes the same rows rather than doubling the board.
///
/// USAGE
///     deno run --allow-net --allow-env --allow-read tool/seed_rivals.ts
///     deno task seed -- --board production
///
/// The service key comes from `npx supabase status` ("Secret") or:
///     docker exec supabase_edge_runtime_<project> printenv SUPABASE_SERVICE_ROLE_KEY

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { cellsCoveringBBox } from "../supabase/functions/_shared/h3.ts";
import { VENUE } from "../supabase/functions/_shared/stubs/venue.ts";

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

const DEFAULT_BASE = "http://127.0.0.1:54321";

/**
 * The three rivals, matching the vocabulary the client and server stubs already use
 * (`StubTerritoryRepository` / `_shared/stubs/territory.ts`) so a seeded board reads
 * the same as a stubbed one.
 */
const RIVALS = [
  { handle: "rival_kat", email: "rival_kat@reprush.local" },
  { handle: "iron_meridian", email: "iron_meridian@reprush.local" },
  { handle: "parkside_crew", email: "parkside_crew@reprush.local" },
] as const;

/** How many cells around the venue to spread the rivals across. */
const DEFAULT_CELLS = 8;
/** Backdate step: cell i's contribution is earned i × this many hours ago. */
const BACKDATE_STEP_H = 15;
/** The active config version (must match the `active` row seeded by 0003). */
const CONFIG_VERSION = VENUE.movementConfigVersion;

function devEnv(): { base?: string } {
  try {
    const path = fileURLToPath(new URL("../supabase/.temp/dev-env.json", import.meta.url));
    return JSON.parse(readFileSync(path, "utf8")) as { base?: string };
  } catch {
    return {};
  }
}

interface Options {
  base: string;
  serviceKey: string;
  board: "production" | "demo";
  cells: number;
}

function parseOptions(args: string[]): Options {
  const dev = devEnv();
  let base = (envOf("SUPABASE_URL") ?? dev.base ?? DEFAULT_BASE).replace(/\/$/, "");
  let serviceKey = envOf("SUPABASE_SERVICE_ROLE_KEY") ?? null;
  let board: "production" | "demo" = "demo";
  let cells = DEFAULT_CELLS;

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = (what: string): string => {
      const value = args[++i];
      if (value === undefined) fail(`--${what} needs a value`);
      return value;
    };
    if (arg === "--base") base = next("base").replace(/\/$/, "");
    else if (arg === "--service-key") serviceKey = next("service-key");
    else if (arg === "--board") {
      const b = next("board");
      if (b !== "production" && b !== "demo") fail(`--board must be 'production' or 'demo'`);
      board = b;
    } else if (arg === "--cells") cells = Number(next("cells"));
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
  if (!Number.isFinite(cells) || cells < 1) fail(`--cells must be a positive number`);

  return { base, serviceKey, board, cells: Math.min(cells, 24) };
}

function usage(): never {
  console.log(`
seed_rivals.ts — seed demo-board territory contest around the venue

    deno run --allow-net --allow-env --allow-read tool/seed_rivals.ts [options]
    deno task seed -- [options]

Options
    --base <url>          Stack URL. Default: $SUPABASE_URL, dev-env.json, or ${DEFAULT_BASE}
    --service-key <key>   Service-role key. Default: $SUPABASE_SERVICE_ROLE_KEY
    --board <b>           'demo' (default) or 'production'. Must match the dev account's
                          board or the rivals will not appear on its map (J7).
    --cells <n>           Cells around the venue to spread across. Default ${DEFAULT_CELLS}, max 24.
    --help                This text.

Creates the three stub-vocabulary rivals (rival_kat, iron_meridian, parkside_crew)
via the auth admin API, patches their handles, and upserts backdated submitted
sessions + hex contributions so the map shows a decay gradient and contestable
cells. Idempotent. Wipe with: deno task reset --all --yes
`);
  throw new HelpRequested();
}

/** A valid, deterministic v4-shaped UUID for stable upserts (rival r, cell c). */
function fixedUuid(r: number, c: number): string {
  const n = (r * 100 + c).toString(16).padStart(12, "0");
  return `f1e2d3c4-0000-4000-8000-${n}`;
}

function authHeaders(serviceKey: string): Record<string, string> {
  return { apikey: serviceKey, authorization: `Bearer ${serviceKey}` };
}

/** Finds an existing auth user by exact email, or null. */
async function findAuthUser(
  base: string,
  serviceKey: string,
  email: string,
): Promise<string | null> {
  const res = await fetch(`${base}/auth/v1/admin/users?filter=${encodeURIComponent(email)}`, {
    headers: authHeaders(serviceKey),
  });
  if (!res.ok) {
    fail(`auth admin lookup returned ${res.status}: ${(await res.text()).slice(0, 200)}`);
  }
  const parsed = JSON.parse(await res.text()) as { users?: { id?: string; email?: string }[] };
  const match = (parsed.users ?? []).find((u) => u.email?.toLowerCase() === email.toLowerCase());
  return match?.id ?? null;
}

/** Creates a rival auth user (firing the signup trigger) and returns its id. */
async function ensureRival(
  base: string,
  serviceKey: string,
  email: string,
  handle: string,
): Promise<string> {
  let id = await findAuthUser(base, serviceKey, email);
  if (id === null) {
    const res = await fetch(`${base}/auth/v1/admin/users`, {
      method: "POST",
      headers: { ...authHeaders(serviceKey), "content-type": "application/json" },
      body: JSON.stringify({ email, password: "local-dev-only-123", email_confirm: true }),
    });
    const text = await res.text();
    if (!res.ok) fail(`creating rival '${email}' returned ${res.status}: ${text.slice(0, 200)}`);
    id = (JSON.parse(text) as { id?: string }).id ?? null;
    if (id === null) fail(`creating rival '${email}' returned no id.`);
  }

  // The trigger gave the profile a generated handle; rename it to the rival handle.
  const patch = await fetch(`${base}/rest/v1/profiles?id=eq.${id}`, {
    method: "PATCH",
    headers: { ...authHeaders(serviceKey), "content-type": "application/json" },
    body: JSON.stringify({ handle }),
  });
  if (!patch.ok) {
    fail(
      `renaming profile '${id}' to '${handle}' returned ${patch.status}: ${
        (await patch.text()).slice(0, 200)
      }`,
    );
  }
  return id;
}

/** Upserts one submitted session so a contribution is visible through the live view. */
async function upsertSession(
  base: string,
  serviceKey: string,
  row: Record<string, unknown>,
): Promise<void> {
  const res = await fetch(`${base}/rest/v1/workout_sessions?on_conflict=id`, {
    method: "POST",
    headers: {
      ...authHeaders(serviceKey),
      "content-type": "application/json",
      prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify([row]),
  });
  if (!res.ok) {
    fail(
      `upserting session '${row.id}' returned ${res.status}: ${(await res.text()).slice(0, 200)}`,
    );
  }
}

/** Upserts one contribution (UNIQUE on session_id) — append-only table, so merge. */
async function upsertContribution(
  base: string,
  serviceKey: string,
  row: Record<string, unknown>,
): Promise<void> {
  const res = await fetch(`${base}/rest/v1/hex_contributions?on_conflict=session_id`, {
    method: "POST",
    headers: {
      ...authHeaders(serviceKey),
      "content-type": "application/json",
      prefer: "resolution=merge-duplicates",
    },
    body: JSON.stringify([row]),
  });
  if (!res.ok) {
    fail(
      `upserting contribution for session '${row.session_id}' returned ${res.status}: ` +
        (await res.text()).slice(0, 200),
    );
  }
}

/**
 * The res-8 cells around the venue, VENUE cell first. A ~±0.01° box (~1.1 km) is
 * small enough to stay well under the route's BBOX limits and large enough to yield
 * a handful of cells; the venue cell is forced into the set so the dev user's own
 * cell is contested (a strong rival contribution there is what makes an overtake —
 * and a flip — demonstrable).
 */
function cellsAroundVenue(limit: number): string[] {
  const box = cellsCoveringBBox(
    VENUE.lat - 0.01,
    VENUE.lng - 0.01,
    VENUE.lat + 0.01,
    VENUE.lng + 0.01,
  );
  const ordered = [VENUE.hexH3, ...box.filter((h) => h !== VENUE.hexH3)];
  return [...new Set(ordered)].slice(0, limit);
}

async function main(): Promise<void> {
  const opts = parseOptions(argv());
  const cells = cellsAroundVenue(opts.cells);
  const nowMs = Date.now();

  console.log(
    `Seeding ${RIVALS.length} rivals across ${cells.length} cells on the '${opts.board}' board.`,
  );

  const rivalIds = new Map<string, string>();
  for (const rival of RIVALS) {
    const id = await ensureRival(opts.base, opts.serviceKey, rival.email, rival.handle);
    rivalIds.set(rival.handle, id);
    console.log(`  ${rival.handle.padEnd(15)} ${id}`);
  }

  // Round-robin the rivals across the cells; the VENUE cell (index 0) goes to the
  // first rival with a strong, fresh contribution so it is contested but winnable
  // once the dev user submits a comparable session.
  let seeded = 0;
  for (let c = 0; c < cells.length; c++) {
    const h3 = cells[c];
    const rival = RIVALS[c % RIVALS.length];
    const userId = rivalIds.get(rival.handle)!;
    const sessionId = fixedUuid(c % RIVALS.length, c);
    const ageMs = c * BACKDATE_STEP_H * 3_600_000;
    const earnedAt = new Date(nowMs - ageMs).toISOString();
    // Power falls off with age across cells so the map shows a visible gradient,
    // while the VENUE cell stays the strongest claim.
    const power = c === 0 ? 900 : 220 + ((c * 37) % 400);

    await upsertSession(opts.base, opts.serviceKey, {
      id: sessionId,
      user_id: userId,
      status: "submitted",
      movement_config_version: CONFIG_VERSION,
      server_start_ms: nowMs - ageMs,
      submitted_at_ms: nowMs - ageMs,
      expires_at_ms: nowMs - ageMs + 3_600_000,
      start_lat: VENUE.lat,
      start_lng: VENUE.lng,
      start_accuracy_m: 8,
      start_is_mocked: false,
      start_h3: h3,
      spot_id: null,
      board: opts.board,
      evidence: null,
    });
    await upsertContribution(opts.base, opts.serviceKey, {
      user_id: userId,
      session_id: sessionId,
      h3,
      power,
      board: opts.board,
      earned_at: earnedAt,
    });
    seeded++;
  }

  console.log(`\nSeeded ${seeded} contributions.`);
  console.log(
    "Next: submit a session as the dev user (deno task submit) to contest the venue cell,",
  );
  console.log("then GET territory/hexes to see the board. Wipe with: deno task reset --all --yes");
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
