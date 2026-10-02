/// End-to-end check of nearby play against a running backend: two brand-new
/// athletes see each other, duel, both post a real scored set, and the winner
/// claims. Exercises `presence` and `duels` together with the real
/// `session-start` / `session-submit` path, which is the only way to prove a
/// duel reads the sets the scorer actually wrote.
///
///     SUPABASE_ANON_KEY=<key> deno task nearby
///     SUPABASE_URL=https://<ref>.supabase.co SUPABASE_ANON_KEY=<key> deno task nearby
///
/// The local key: `docker exec supabase_edge_runtime_reprush printenv SUPABASE_ANON_KEY`.
/// Needs `session-start,session-submit` in LIVE_ENDPOINTS (the default .env).
///
/// Fresh accounts every run (timestamped emails), so it never trips the daily
/// session cap or an open duel left by a previous run. Takes about as long as
/// the fixture set it submits (~1 min): the wall-clock gate (I3) needs the
/// server to observe the set's duration.
///
/// CLEANUP. The test athletes post real sets, so they capture a real hex and
/// would sit on the territory leaderboard. With SUPABASE_SERVICE_ROLE_KEY set,
/// both accounts are deleted at the end (every row cascades from the auth
/// user), pass or fail. Without it they are left behind and the tool says so —
/// never run it against a shared backend without the key.

import { FIXTURES, SESSION_START_MS, VENUE } from "../test/server/tools/fixtures.ts";

const BASE = (Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321").replace(/\/$/, "");
const ANON = Deno.env.get("SUPABASE_ANON_KEY");
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
if (!ANON) throw new Error("Set SUPABASE_ANON_KEY (see the header of tool/nearby_smoke.ts).");

interface Athlete {
  name: string;
  token: string;
  id: string;
}

interface Reply {
  status: number;
  // deno-lint-ignore no-explicit-any
  body: any;
}

async function call(who: Athlete, method: string, path: string, body?: unknown): Promise<Reply> {
  const response = await fetch(`${BASE}/functions/v1/${path}`, {
    method,
    headers: {
      apikey: ANON!,
      authorization: `Bearer ${who.token}`,
      "content-type": "application/json",
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let parsed: unknown = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // keep text
  }
  return { status: response.status, body: parsed };
}

async function signUp(name: string): Promise<Athlete> {
  const response = await fetch(`${BASE}/auth/v1/signup`, {
    method: "POST",
    headers: { apikey: ANON!, "content-type": "application/json" },
    body: JSON.stringify({
      email: `nearby-${name}-${Date.now()}@reprush.test`,
      password: "nearby-smoke-123",
    }),
  });
  const body = await response.json();
  if (!response.ok || !body.access_token) {
    throw new Error(`signup ${name} failed: ${response.status} ${JSON.stringify(body)}`);
  }
  return { name, token: body.access_token, id: body.user.id };
}

let failures = 0;
function check(label: string, ok: boolean, detail?: unknown): void {
  console.log(`${ok ? "  ok  " : "  FAIL"} ${label}`);
  if (!ok) {
    failures++;
    if (detail !== undefined) console.log("       ", JSON.stringify(detail));
  }
}

function at(lat: number, lng: number, extra: Record<string, unknown> = {}) {
  return { location: { lat, lng, accuracyM: 10, isMocked: false, ...extra } };
}

/** One real set, submitted after the span the server needs to observe (I3). */
async function postSet(who: Athlete, fixtureName: string): Promise<Reply> {
  const { fixture } = FIXTURES.find((f) => f.name === fixtureName)!;
  const start = await call(who, "POST", "session-start", at(VENUE.lat, VENUE.lng));
  if (start.status !== 200) return start;
  await new Promise((r) => setTimeout(r, fixture.submitAtMs - SESSION_START_MS));
  return await call(who, "POST", "session-submit", {
    ...fixture.evidence,
    sessionId: start.body.sessionId,
    movementConfigVersion: start.body.movementConfigVersion,
    spotId: start.body.spotId,
  });
}

console.log(`\nnearby play smoke test against ${BASE}\n`);
const a = await signUp("a");
const b = await signUp("b");
try {
  await run();
} finally {
  await cleanUp([a, b]);
}
console.log(failures === 0 ? "\nall checks passed\n" : `\n${failures} check(s) FAILED\n`);
if (failures > 0) Deno.exit(1);

/** Deletes the test athletes; their sessions, hexes and duels cascade. */
async function cleanUp(athletes: Athlete[]): Promise<void> {
  if (!SERVICE) {
    console.log(
      `\nleft behind: ${athletes.map((x) => x.id).join(", ")} — set ` +
        "SUPABASE_SERVICE_ROLE_KEY to have them deleted.",
    );
    return;
  }
  for (const who of athletes) {
    const response = await fetch(`${BASE}/auth/v1/admin/users/${who.id}`, {
      method: "DELETE",
      headers: { apikey: SERVICE, authorization: `Bearer ${SERVICE}` },
    });
    await response.body?.cancel();
    console.log(`${response.ok ? "  ok  " : "  FAIL"} deleted test athlete ${who.name}`);
  }
}

async function run(): Promise<void> {
  // ~500 m apart: neighbouring hexes, well inside the 3-ring.
  const bLat = VENUE.lat + 0.0045;

  console.log("presence");
  const mocked = await call(a, "POST", "presence", at(VENUE.lat, VENUE.lng, { isMocked: true }));
  check("a mocked fix is refused", mocked.body?.code === "MOCKED_LOCATION_REJECTED", mocked);
  let beat = await call(a, "POST", "presence", at(VENUE.lat, VENUE.lng));
  check("A's heartbeat answers with a list", beat.status === 200 && Array.isArray(beat.body), beat);
  beat = await call(b, "POST", "presence", at(bLat, VENUE.lng));
  const seenByB = beat.body.find?.((p: { userId: string }) => p.userId === a.id);
  check("B sees A", seenByB !== undefined, beat);
  check("…placed by hex centre, not A's fix", seenByB && seenByB.centre.lat !== VENUE.lat, seenByB);
  beat = await call(a, "POST", "presence", at(VENUE.lat, VENUE.lng));
  check("A sees B", beat.body.some?.((p: { userId: string }) => p.userId === b.id), beat);
  check(
    "nobody sees themselves",
    !beat.body.some?.((p: { userId: string }) => p.userId === a.id),
  );
  const far = await call(a, "POST", "presence", at(VENUE.lat + 0.2, VENUE.lng));
  check(
    "from 20 km away, B is not nearby",
    !far.body.some?.((p: { userId: string }) => p.userId === b.id),
    far,
  );
  await call(a, "POST", "presence", at(VENUE.lat, VENUE.lng));

  console.log("\nduel");
  let r = await call(a, "POST", "duels", { opponentId: b.id, movementId: "squat" });
  check("A challenges B", r.status === 200 && r.body.status === "pending", r);
  const duelId = r.body.id;
  r = await call(a, "POST", "duels", { opponentId: b.id, movementId: "squat" });
  check("a second open duel is refused", r.body?.code === "DUEL_ALREADY_OPEN", r);
  r = await call(a, "POST", `duels/${duelId}/accept`);
  check("the challenger cannot accept their own challenge", r.status === 404, r);
  r = await call(b, "GET", "duels");
  const incoming = r.body.find?.((d: { id: string }) => d.id === duelId);
  check("B sees it as incoming", incoming?.incoming === true && incoming.status === "pending", r);
  r = await call(b, "POST", `duels/${duelId}/accept`);
  check("B accepts → active", r.body?.status === "active" && r.body.endsAtMs > Date.now(), r);
  r = await call(b, "POST", `duels/${duelId}/accept`);
  check("answering twice is refused", r.body?.code === "DUEL_CLOSED", r);
  r = await call(a, "POST", `duels/${duelId}/claim`);
  check("no claim mid-duel", r.body?.code === "DUEL_CLOSED", r);

  console.log("\nboth athletes post a real set (about a minute)…");
  const [setA, setB] = await Promise.all([
    postSet(a, "squat_20_clean"),
    postSet(b, "squat_shallow"),
  ]);
  check("A's set scored", setA.status === 200, setA);
  check("B's set scored", setB.status === 200, setB);

  r = await call(a, "GET", "duels");
  const done = r.body.find?.((d: { id: string }) => d.id === duelId);
  check("finished once both sets are in", done?.status === "finished", done);
  console.log(`       A ${done?.myReps} – ${done?.theirReps} B → ${done?.result}`);
  check("reps came from the server's set records", typeof done?.myReps === "number", done);
  const before = await call(a, "GET", "me");
  r = await call(a, "POST", `duels/${duelId}/claim`);
  check(`A claims +${done?.xpReward} XP`, r.body?.xpAwarded === done?.xpReward, r);
  const after = await call(a, "GET", "me");
  check(
    "the claim shows up in A's XP",
    after.body.xp - before.body.xp === done?.xpReward,
    { before: before.body.xp, after: after.body.xp },
  );
  r = await call(a, "POST", `duels/${duelId}/claim`);
  check("claiming twice is refused", r.body?.code === "ALREADY_CLAIMED", r);

  console.log("\nyour territory, anywhere");
  r = await call(a, "GET", "territory/mine");
  const owned = Array.isArray(r.body) ? r.body : [];
  check(
    "A's set claimed a hex that territory/mine lists, with its outline",
    owned.length === 1 && owned[0].yours === true && owned[0].polygon?.length === 6,
    r,
  );
  r = await call(b, "GET", "territory/mine");
  check("B, out-powered there, holds nothing", Array.isArray(r.body) && r.body.length === 0, r);

  console.log("\ngoing hidden");
  await call(b, "POST", "presence/off");
  beat = await call(a, "POST", "presence", at(VENUE.lat, VENUE.lng));
  check(
    "B vanishes at once",
    !beat.body.some?.((p: { userId: string }) => p.userId === b.id),
    beat,
  );
  await call(a, "POST", "presence/off");
}
