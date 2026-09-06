/// Submits an authored fixture to a running backend and compares what comes back
/// against the fixture's golden.
///
///     node tool/submit_fixture.ts squat_20_clean
///     node tool/submit_fixture.ts --list
///     node tool/submit_fixture.ts squat_metronome --dry-run
///
///     deno task submit squat_20_clean
///
/// WHY THIS EXISTS SEPARATELY FROM THE TEST SUITE
/// `golden_test.ts` proves the pure pipeline produces the golden's numbers. It
/// cannot prove the DEPLOYED pipeline does: that the route order is right, that
/// `parseEvidence` sees the same bytes the client would send, that the session
/// gates pass against a real row, that the ledger write succeeds and the C4
/// response is shaped the way `SubmitResult` in models.dart expects. Those are all
/// outside the pure tree, and this is the only thing that exercises them.
///
/// THE THREE FIELDS THAT MUST BE REBOUND
/// A fixture is authored against a fictional session. Three of its fields are
/// server-decided and cannot survive the trip unchanged — `POST /session/start`
/// is what issues them (I2, and api-contract.md §Session lifecycle):
///
///     sessionId              server-generated; no locally minted id is accepted
///     movementConfigVersion  bound from the active row at start, so a client
///                            cannot select a more forgiving threshold set
///     spotId                 the session's context; territory resolves from the
///                            server-recorded start row, never from the payload
///
/// Everything else travels as authored. In particular the `*Ms` fields are OFFSETS
/// from the client's session start, not epoch timestamps, so they are already
/// correct for a brand-new session — that is exactly the property I3 rests on.
///
/// THE WAIT, AND WHY IT REPLAYS THE AUTHORED OFFSET
/// I3 compares two DURATIONS: the span the evidence claims against the window the
/// server itself observed (`submitMs - serverStartMs`). The submit delay is
/// therefore an input to the gate, not a detail of the harness — and every fixture
/// authors one (`submitAtMs` in fixtures.ts). The default is `lastEnd + 5000`,
/// which covers the span and passes; `squat_replay_bad_clock` overrides it to
/// +40 s against a 177 s span, and that override IS the rejection.
///
/// Waiting for the span to fit instead — the obvious reading, and the one this
/// tool originally had — silently turns the only gate fixture in the set into an
/// accepted one: it waits 172 s, the window then covers the span, the session is
/// consumed, a score is awarded, and the tool reports a divergence that is its own
/// fault. So the wait reproduces the authored offset and nothing else.
/// `--no-wait` submits immediately, which is how you watch the gate reject a
/// fixture that was authored to pass.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { FIXTURES, SESSION_START_MS } from "../test/server/tools/fixtures.ts";
import type { Fixture } from "../test/server/tools/fixtures.ts";
import type { Golden } from "../test/server/tools/golden.ts";
import type { Consequences } from "../supabase/functions/_shared/stubs/consequences.ts";
import type { SessionStartResponse } from "../supabase/functions/_shared/stubs/session-start.ts";
import type { Evidence } from "../supabase/functions/_shared/evidence/schema.ts";
import { WALLCLOCK_SLACK_MS } from "../supabase/functions/_shared/validation/wallclock.ts";
import { round } from "../supabase/functions/_shared/scoring/score.ts";

const FIXTURE_DIR = fileURLToPath(new URL("../test/server/fixtures/", import.meta.url));

/**
 * Safety rail on the wait, not a way to classify fixtures. Every authored offset
 * is under three minutes; this exists so a typo in a fixture cannot hang a demo
 * rehearsal for an hour. Hitting it is a bug in the fixture — rejection cases are
 * told apart by comparing the offset against the span, not by their length.
 */
const MAX_WAIT_MS = 10 * 60 * 1000;

// ---------------------------------------------------------------------------
// Runtime plumbing — argv and env across both runtimes
// ---------------------------------------------------------------------------

// Written against `globalThis` rather than naming either runtime, the same way
// `_shared/env.ts` does it, so one file runs under `node` and `deno run`.
const runtime = globalThis as {
  Deno?: { args: string[]; env: { get(name: string): string | undefined } };
  process?: { argv: string[]; env: Record<string, string | undefined>; exitCode?: number };
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
  // Throwing rather than setting an exit code: both runtimes turn an uncaught
  // exception into a non-zero exit, and `process` may not exist at all.
  throw new Error(message);
}

interface Options {
  fixture: string | null;
  base: string | null;
  token: string | null;
  apikey: string | null;
  list: boolean;
  dryRun: boolean;
  noWait: boolean;
}

/**
 * `tool/dev_user.ts` writes the credentials it minted to `supabase/.temp/dev-env.json`.
 * Reading them back is what turns "prove the DEPLOYED pipeline works" from a
 * copy-paste-a-470-character-JWT exercise into one command. That matters more than
 * convenience: a token you have to paste is a token you keep pasting after it
 * expires, and an expired token reads as a backend failure rather than what it is.
 *
 * Explicit flags and env vars still win — this is the fallback of last resort, and
 * quietly overriding an explicit `--token` would be worse than not having it.
 * A missing or unreadable file yields `{}`, so the caller still reports the
 * credential it is actually missing.
 */
function devEnv(): { functionsBase?: string; token?: string; anonKey?: string } {
  try {
    const path = fileURLToPath(new URL("../supabase/.temp/dev-env.json", import.meta.url));
    return JSON.parse(readFileSync(path, "utf8")) as {
      functionsBase?: string;
      token?: string;
      anonKey?: string;
    };
  } catch {
    return {};
  }
}

function parseOptions(args: string[]): Options {
  const dev = devEnv();
  const url = envOf("SUPABASE_URL");
  const opts: Options = {
    fixture: null,
    base: url === undefined ? dev.functionsBase ?? null : `${url}/functions/v1`,
    token: envOf("REPRUSH_TOKEN") ?? dev.token ?? null,
    apikey: envOf("SUPABASE_ANON_KEY") ?? dev.anonKey ?? null,
    list: false,
    dryRun: false,
    noWait: false,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = (what: string): string => {
      const value = args[++i];
      if (value === undefined) fail(`--${what} needs a value`);
      return value;
    };
    if (arg === "--list") opts.list = true;
    else if (arg === "--dry-run") opts.dryRun = true;
    else if (arg === "--no-wait") opts.noWait = true;
    else if (arg === "--base") opts.base = next("base").replace(/\/$/, "");
    else if (arg === "--token") opts.token = next("token");
    else if (arg === "--apikey") opts.apikey = next("apikey");
    else if (arg === "--help" || arg === "-h") usage();
    else if (arg.startsWith("--")) fail(`unknown option '${arg}' — try --help`);
    else if (opts.fixture === null) opts.fixture = arg;
    else fail(`unexpected argument '${arg}' — only one fixture at a time`);
  }
  return opts;
}

function usage(): never {
  console.log(`
submit_fixture.ts — send an authored fixture to a running backend

    node tool/submit_fixture.ts <fixture> [options]

Options
    --base <url>     Functions base. Default: $SUPABASE_URL/functions/v1
    --token <jwt>    A real USER access token. Default: $REPRUSH_TOKEN
    --apikey <key>   Sent as the 'apikey' header. Default: $SUPABASE_ANON_KEY

    All three fall back to supabase/.temp/dev-env.json, which "deno task user"
    writes. So the usual live run is:  deno task user && deno task submit <fixture>
    --no-wait        Submit immediately instead of waiting out the fixture's
                     authored submit offset. Use this to watch the wall-clock
                     gate reject a fixture that was authored to pass.
    --dry-run        Rebind and print what would be sent; touch no network.
    --list           List the authored fixtures and what each demonstrates.

Notes
    The token must resolve through auth.getUser — an anon key is not a user and
    will 401. "deno task user" mints one against the local stack; a 401 here
    usually means the token in dev-env.json outlived its one-hour expiry, so rerun
    it rather than debugging the backend.

    Each live run consumes one session AND one slot of the 20-per-day budget
    (MAX_SESSIONS_PER_DAY), so the 21st start in a UTC day returns 429.
`);
  // Exit 0 for --help: it is not a failure.
  throw new HelpRequested();
}

class HelpRequested extends Error {
  constructor() {
    super("--help");
    this.name = "HelpRequested";
  }
}

// ---------------------------------------------------------------------------
// Rebinding
// ---------------------------------------------------------------------------

/** What `POST /session/start` gives back, narrowed to what this tool uses. */
interface StartResult {
  sessionId: string;
  serverStartMs: number;
  movementConfigVersion: string;
  spotId: string | null;
  expiresAtMs: number;
}

/**
 * Produces the Evidence this session will actually accept.
 *
 * Deliberately a whole-object rebuild rather than three assignments in place: the
 * returned object is what gets serialised and sent, and building it explicitly
 * means a new server-decided field cannot be silently forgotten.
 */
function rebind(evidence: Evidence, start: StartResult): Evidence {
  return {
    ...evidence,
    sessionId: start.sessionId,
    movementConfigVersion: start.movementConfigVersion,
    spotId: start.spotId,
    // `location` is NOT rebound, and that is on purpose. The start request below
    // is sent with the fixture's own location, so the server-recorded start fix
    // and the submitted one agree by construction and the drift is zero. For a
    // demo account the server substitutes its own venue fix instead (J7), which
    // agrees only because every fixture is authored at that same venue.
  };
}

/** The claimed span the I3 window has to accommodate. */
function claimedSpanMs(evidence: Evidence): number {
  if (evidence.sets.length === 0) return 0;
  return Math.max(...evidence.sets.map((s) => s.endedAtMs));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** The offset this fixture authors for its own submission, in ms after start. */
function submitDelayMs(fixture: Fixture): number {
  return fixture.submitAtMs - SESSION_START_MS;
}

/**
 * Waits until the session has been open for as long as the fixture authors.
 *
 * Returns a warning string if the offset is past the rail, otherwise null once
 * the window has been reached.
 *
 * The delay is measured from the SERVER's start stamp against the local clock, so
 * a badly skewed local clock reproduces the wrong window. That is unavoidable — I3
 * exists precisely because the server cannot trust the client's clock — and the
 * failure mode is safe: the gate rejects and this tool reports a divergence,
 * rather than a score being silently awarded for a window that never happened.
 */
async function waitForSubmitDelay(serverStartMs: number, delayMs: number): Promise<string | null> {
  if (delayMs <= 0) return null;
  if (delayMs > MAX_WAIT_MS) {
    return (
      `the authored submit offset is ${(delayMs / 1000).toFixed(0)} s, past the ` +
      `${MAX_WAIT_MS / 1000} s rail — check fixtures.ts, this is almost certainly a typo`
    );
  }

  console.log(`  waiting ${(delayMs / 1000).toFixed(0)} s to submit at the authored offset…`);
  for (;;) {
    const remainingMs = delayMs - (Date.now() - serverStartMs);
    if (remainingMs <= 0) return null;
    const remainingS = Math.ceil(remainingMs / 1000);
    console.log(`    ${remainingS} s remaining`);
    // 5 s ticks: long enough not to spam, short enough that Ctrl-C feels
    // responsive and the final submit lands within a few seconds of the offset.
    await sleep(Math.min(5000, remainingMs));
  }
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function headers(opts: Options): Record<string, string> {
  const out: Record<string, string> = {
    "content-type": "application/json",
    // Matches clientPlatform() in _shared/auth.ts. A header rather than a body
    // field because submit's body must stay the §evidence object verbatim — that
    // is precisely what gets stored in workout_sessions.evidence.
    "x-reprush-platform": "web",
  };
  if (opts.token !== null) out["authorization"] = `Bearer ${opts.token}`;
  if (opts.apikey !== null) out["apikey"] = opts.apikey;
  return out;
}

interface CallResult {
  status: number;
  body: unknown;
}

async function post(opts: Options, path: string, body: unknown): Promise<CallResult> {
  const url = `${opts.base}/${path}`;
  const response = await fetch(url, {
    method: "POST",
    headers: headers(opts),
    body: JSON.stringify(body),
  });
  // Never let a non-JSON body (a Supabase 502 page, a proxy error) throw
  // unreadably — the text is the useful part.
  const text = await response.text();
  let parsed: unknown = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // leave as text
  }
  return { status: response.status, body: parsed };
}

// ---------------------------------------------------------------------------
// Comparison against the golden
// ---------------------------------------------------------------------------

/**
 * What the C4 response can actually confirm.
 *
 * The golden carries far more than this — every flag, every per-rep romScore,
 * every tempo statistic. None of that is in the HTTP response: flags go to
 * `session_flags` and the per-rep detail goes to `rep_events`, so checking them
 * needs a database query, not a POST. Pretending otherwise would make this tool
 * look like it verifies more than it does.
 */
function compareToGolden(golden: Golden, call: CallResult): string[] {
  const problems: string[] = [];

  if (golden.gate !== null) {
    // A rejection fixture: the live route must refuse with the same code and
    // status. This is the strongest thing the tool can check, because the gate
    // outcome is the whole response.
    if (call.status !== golden.gate.status) {
      problems.push(`expected status ${golden.gate.status}, got ${call.status}`);
    }
    // `call.body` is a string when the response was not JSON — a Supabase 502
    // page, a proxy error. Narrowing rather than casting, because the cast
    // version silently produced `undefined` for those and reported it as a code
    // mismatch, which is true but useless; the text is the diagnosable part.
    const body = call.body;
    const code = typeof body === "object" && body !== null
      ? (body as { code?: unknown }).code
      : undefined;
    if (code !== golden.gate.code) {
      const got = code === undefined
        ? `no JSON code (body: ${String(body).slice(0, 120)})`
        : String(code);
      problems.push(`expected code ${golden.gate.code}, got ${got}`);
    }
    return problems;
  }

  if (call.status !== 200) {
    problems.push(`expected 200, got ${call.status}`);
    return problems;
  }

  const body = call.body as Consequences;
  const expectedXp = golden.score!.xp;
  if (body.xp !== expectedXp) {
    problems.push(`xp: golden ${expectedXp}, live ${body.xp}`);
  }

  // The territory half is a documented stub, so what is checkable is the
  // relationship the stub asserts: hex power equals the awarded total, and a
  // session that scored nothing claims nothing.
  //
  // BOTH SIDES GO THROUGH round(). The golden file stores `round(awardedTotal)`
  // (golden.ts:210, 6 decimal places) while the live response carries the raw
  // double, and those are not the same number: 20 reps at formFactor 0.981996 is
  // 19.639920000000004 on the wire and 19.63992 in the golden. Comparing them
  // with !== reports a divergence on the very first clean run, which is worse
  // than not comparing at all — it teaches you to ignore this tool's verdict.
  // Importing the golden writer's own `round` rather than restating a tolerance
  // keeps the two policies identical by construction instead of by coincidence.
  const awarded = golden.score!.awardedTotal;
  if (awarded > 0) {
    const power = body.hexResult === null ? null : round(body.hexResult.power);
    const yourPower = body.hexResult === null ? null : round(body.hexResult.yourPower);
    if (body.hexResult === null) {
      problems.push(`awarded ${awarded} but hexResult is null — no capture reported`);
    } else if (power !== awarded) {
      problems.push(
        `hexResult.power: golden awardedTotal ${awarded}, live ${body.hexResult.power}`,
      );
    } else if (yourPower !== awarded) {
      // consequences.ts documents `power === yourPower` as the visible symptom of
      // the missing claim table, so it holds exactly until that table lands.
      problems.push(
        `hexResult.yourPower: expected ${awarded} (no contest table yet), ` +
          `live ${body.hexResult.yourPower}`,
      );
    }
  } else if (body.hexResult !== null) {
    problems.push("awarded 0 but hexResult claims a capture");
  }

  // These are stubbed empty on purpose. If they ever come back populated, the
  // real implementations have landed and this assertion should be replaced rather
  // than deleted — a fabricated PR or unlock is a lie on stage.
  for (const field of ["unlocks", "prs", "achievements"] as const) {
    const value = body[field];
    if (!Array.isArray(value) || value.length !== 0) {
      problems.push(`${field}: expected an empty stub array, got ${JSON.stringify(value)}`);
    }
  }
  if (body.voided !== false) problems.push("voided must be false on the write path");

  return problems;
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

function readGolden(name: string): Golden {
  try {
    return JSON.parse(readFileSync(`${FIXTURE_DIR}${name}.expected.json`, "utf8")) as Golden;
  } catch {
    return fail(
      `no golden for '${name}' at ${FIXTURE_DIR}${name}.expected.json — ` +
        "run `node test/server/tools/build_fixtures.ts` first",
    );
  }
}

async function main(): Promise<void> {
  const opts = parseOptions(argv());

  if (opts.list) {
    console.log(`\n${FIXTURES.length} authored fixtures:\n`);
    for (const { name } of FIXTURES) {
      const golden = readGolden(name);
      const summary = golden.gate !== null
        ? `REJECTED ${golden.gate.status} ${golden.gate.code}`
        : `awarded ${golden.score!.awardedTotal}, xp ${golden.score!.xp}, ` +
          `${golden.score!.flags.length} flag(s)`;
      console.log(`  ${name.padEnd(28)} ${summary}`);
    }
    console.log();
    return;
  }

  if (opts.fixture === null) {
    console.error("no fixture named — try --list or --help");
    throw new Error("no fixture named");
  }

  const entry = FIXTURES.find((f) => f.name === opts.fixture);
  if (entry === undefined) {
    fail(
      `no fixture '${opts.fixture}'. Known: ${FIXTURES.map((f) => f.name).join(", ")}`,
    );
  }
  const { fixture } = entry;
  const golden = readGolden(opts.fixture);

  console.log(`\n── ${opts.fixture} ` + "─".repeat(Math.max(0, 58 - opts.fixture.length)));
  console.log(fixture.about.replace(/\s+/g, " "));
  console.log(
    golden.gate !== null
      ? `\ngolden: REJECTED ${golden.gate.status} ${golden.gate.code}`
      : `\ngolden: awarded ${golden.score!.awardedTotal}, xp ${golden.score!.xp}, ` +
        `${golden.score!.flags.length} flag(s) [${
          [...new Set(golden.score!.flags.map((f) => f.code))].join(", ")
        }]`,
  );

  if (opts.dryRun || opts.base === null || opts.token === null) {
    if (!opts.dryRun) {
      console.log(
        "\nno --base or --token (run `deno task user`, or set SUPABASE_URL and REPRUSH_TOKEN)",
      );
    }
    // Still worth something offline: show exactly what would go on the wire, with
    // the three server-decided fields marked. The fixture's own values are what a
    // naive client would send, and every one of them would be rejected.
    const span = claimedSpanMs(fixture.evidence);
    const delay = submitDelayMs(fixture);
    // Both durations are known locally, so the gate's verdict can be predicted
    // without a network — which is the one genuinely useful thing a dry run of a
    // rejection fixture can tell you.
    const shortfall = span - WALLCLOCK_SLACK_MS - delay;
    console.log("\ndry run — the payload as authored, before rebinding:");
    console.log(`  sessionId              ${fixture.evidence.sessionId}   (rebound from start)`);
    console.log(
      `  movementConfigVersion  ${fixture.evidence.movementConfigVersion}   (rebound from start)`,
    );
    console.log(
      `  spotId                 ${String(fixture.evidence.spotId)}   (rebound from start)`,
    );
    console.log(`  sets                   ${fixture.evidence.sets.length}`);
    console.log(`  claimed span           ${span} ms`);
    console.log(`  authored submit offset ${delay} ms after start`);
    console.log(
      shortfall <= 0
        ? "  → the offset covers the span, so I3 passes and the scorer runs"
        : `  → the offset is ${shortfall} ms short of the span, so I3 rejects it — ` +
          "this is what the golden predicts",
    );
    console.log("\nnothing sent.");
    return;
  }

  // 1. Open a real session. This is what issues the three server-decided fields.
  console.log("\nPOST /session/start");
  const startCall = await post(opts, "session-start", {
    // Sent with the FIXTURE's location so the server-recorded start fix and the
    // submitted one agree by construction — see the note in rebind().
    location: fixture.evidence.location,
    spotId: fixture.evidence.spotId,
  });
  if (startCall.status !== 200) {
    console.log(`  ${startCall.status} ${JSON.stringify(startCall.body)}`);
    fail("session/start did not return 200 — nothing was submitted");
  }
  const start = startCall.body as SessionStartResponse;
  const startResult: StartResult = {
    sessionId: start.sessionId,
    serverStartMs: start.serverStartMs,
    movementConfigVersion: start.movementConfigVersion,
    spotId: start.spotId,
    expiresAtMs: start.expiresAtMs,
  };
  console.log(`  session            ${startResult.sessionId}`);
  console.log(`  serverStartMs      ${startResult.serverStartMs}`);
  console.log(`  configVersion      ${startResult.movementConfigVersion}`);
  console.log(`  spotId             ${String(startResult.spotId)}`);

  if (startResult.movementConfigVersion !== fixture.evidence.movementConfigVersion) {
    console.log(
      `  note: the live config version differs from the fixture's ` +
        `'${fixture.evidence.movementConfigVersion}'. Rebinding to the live one, so the golden's ` +
        `numbers only match if the offsets are identical across the two versions.`,
    );
  }

  const evidence = rebind(fixture.evidence, startResult);

  // 2. Wait out the fixture's authored submit offset. The span is printed as
  // context only — the offset is what I3 measures it against.
  const span = claimedSpanMs(evidence);
  const delay = submitDelayMs(fixture);
  console.log(`\nclaimed span ${span} ms; submitting at the authored offset of ${delay} ms`);
  const giveUp = opts.noWait
    ? "skipped: --no-wait, submitting immediately"
    : await waitForSubmitDelay(startResult.serverStartMs, delay);
  if (giveUp !== null) console.log(`  ${giveUp}`);

  // 3. Submit.
  console.log("\nPOST /session/submit");
  const submitCall = await post(opts, "session-submit", evidence);
  console.log(`  ${submitCall.status}`);
  console.log(JSON.stringify(submitCall.body, null, 2).split("\n").map((l) => `  ${l}`).join("\n"));

  // 4. Compare.
  const problems = compareToGolden(golden, submitCall);
  console.log("");
  if (problems.length === 0) {
    console.log("MATCHES THE GOLDEN on everything the C4 response exposes.");
    console.log(
      "Flags and per-rep detail are not in the response — query session_flags and\n" +
        "rep_events to check those.",
    );
  } else {
    console.log(`DIVERGES FROM THE GOLDEN (${problems.length}):`);
    for (const p of problems) console.log(`  · ${p}`);
    // A divergence here is the interesting outcome: the pure tree and the
    // deployed one disagree, which the test suite alone cannot detect.
    fail("live response does not match the golden");
  }
  console.log("");
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
