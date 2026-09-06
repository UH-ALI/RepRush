# Track B — Backend Scaffolding Plan (Day 1)

**Owner: B (Dev 2).** Companion to [requirements.md](requirements.md), [roles.md](roles.md), and
[api-contract.md](api-contract.md). This is the concrete setup sequence for B-1 through B-4 and B-24
— everything that must exist by end of Day 1 so that C is never blocked and B's Day 2 (scoring
against fixtures) starts cold-open.

Incorporates the agreed plan adjustments: **guest auth first** (social login deferred), **deny-all
RLS posture** (not per-table policy work), **stubs served from real Edge Function routes** (not
client-side fakes), and the **h3-pg check with h3-js fallback**.

---

## 0. Sequence at a glance

| # | Step                               | Time box | Output                                                              |
| - | ---------------------------------- | -------- | ------------------------------------------------------------------- |
| 1 | Project + CLI + local stack        | 1 h      | `supabase start` running, project linked                            |
| 2 | **h3 extension check**             | 15 min   | Decision recorded: h3-pg or h3-js-in-function                       |
| 3 | Schema migration                   | 2–3 h    | All tables from [requirements.md §3](requirements.md), deny-all RLS |
| 4 | Movement catalogue seed            | 30 min   | `movements` frozen per §4 table                                     |
| 5 | Guest auth + device binding        | 45 min   | Anonymous sign-in works from a curl'd JWT                           |
| 6 | Edge Function scaffold, stub-first | 2–3 h    | Every endpoint live, returning realistic canned JSON                |
| 7 | Evidence fixtures                  | 1 h      | 3–4 hand-authored `evidence.json` in `test/server/fixtures/`        |
| 8 | Dart model types                   | 1 h      | `lib/models/` mirrors the contract                                  |
| 9 | Env + keys distribution            | 15 min   | `.env` pattern, keys to A and C, nothing committed                  |

Total ≈ a full day with slack. Steps 7–8 can slip to Day 2 morning **only** if step 6 lands — the
stubs are the hard deadline ([roles.md §2 B-3](roles.md)).

---

## 1. Project + CLI + local stack

```sh
# once per machine
npm i -g supabase            # or scoop/brew
supabase login

# in repo root
supabase init                # creates supabase/ (B-owned per roles.md §3)
supabase start               # local stack via Docker — Postgres, auth, functions
```

Create the hosted project in the Supabase dashboard (free tier), then:

```sh
supabase link --project-ref <ref>
```

**Rule:** develop and test against the **local** stack all week; push migrations to the hosted
project at each day's integration check. The hosted project is what the demo phone talks to — treat
it like production from Day 3.

---

## 2. The h3 decision — 15 minutes, first thing

Check whether the `h3` / `h3_postgis` extensions are enabled on the hosted project's tier:

```sql
select * from pg_available_extensions where name like 'h3%';
```

- **Available** → `create extension h3;` in the first migration; hex index + boundary computation in
  SQL.
- **Not available** → compute H3 in the Edge Functions with **h3-js** (Deno:
  `import { latLngToCell, cellToBoundary, polygonToCells } from "npm:h3-js@4"`), store the index as
  `text`. This path is arguably simpler anyway — no SQL extension surface, and the client already
  never sees H3 either way ([requirements.md §8 open-1](requirements.md)).

Record the decision at the top of the first migration file. Either way the client API is identical:
plain polygons out, nothing else.

---

## 3. Schema migration

One migration file to start: `supabase/migrations/0001_core.sql`. Tables straight from the domain
model ([requirements.md §3](requirements.md)):

```
profiles              id (=auth.uid), handle, avatar_url, level, lifetime_score, home_spot_id
devices               id, user_id, platform, attestation_state, created_at
movements             id (text, e.g. 'pull_up'), family, tier, measurement_type,
                      difficulty numeric, joint_config jsonb, placement_hint
unlocked_movements    user_id, movement_id, unlocked_at, qualifying_session_id
workout_sessions      id uuid (server-issued), user_id, started_at, submitted_at,
                      h3_index text, spot_id nullable, status ('open'|'submitted'|'expired'|'voided'),
                      expires_at (start + 4 h)                                   -- I2
set_records           id, session_id, movement_id, rep_count, hold_ms, form_score,
                      tempo_stats jsonb, scored bool
rep_events            id, set_id, t_start_ms, t_end_ms, rest_extreme, peak_extreme,
                      conf_mean, conf_min, concentric_ms, eccentric_ms,
                      hip_drift_norm, shoulder_wrist_dy_norm
pose_traces           set_id, hz, t0_ms, primary_signal numeric[], conf_mean numeric[]   -- I8
score_ledger          id, user_id, session_id, points numeric, reason, voided bool,
                      created_at                                                 -- append-only: no UPDATE/DELETE grants; voiding sets the flag via service role only
hexes                 h3_index text pk, owner_id, power numeric, power_updated_at
spots                 id, name, type, location geography(point), h3_index text,
                      verified bool default false, owner_id, created_by
claims                id, target_type ('hex'|'spot'), target_id text, user_id,
                      power numeric, created_at
personal_records      user_id, movement_id, metric, value, session_id
achievements          id, name, criteria jsonb          -- seeded Day 5, table exists now
user_achievements     user_id, achievement_id, awarded_at
challenges            id, day, spec jsonb               -- Day 5, table exists now
challenge_progress    user_id, challenge_id, progress, claimed_at
```

Notes that save pain later:

- `create extension postgis;` — needed for `spots.location` and the 100 m `ST_DWithin` check-in
  (E2).
- **Decay is lazy** (D3): no cron, no `power` mutation on read. Effective power is always computed
  as `power * pow(0.5, extract(epoch from now() - power_updated_at) / (72*3600))` at read time; the
  stored value only changes on write (claim), when it's first collapsed to its decayed value and
  `power_updated_at` reset.
- **Ledger is append-only** (§3 rule 1): revoke UPDATE/DELETE from every role except the void path
  in the service role; the void path flips `voided`, never deletes.
- `workout_sessions.status` transitions are the one-shot mechanism (I2): `open → submitted` exactly
  once; a second submit against the same id fails on the status check, atomically.

### RLS posture — the simplification

```sql
alter table <every table> enable row level security;
-- and write NO policies for writes
```

No client write policy exists on any table → all writes are denied to the anon/authenticated roles
and only Edge Functions (service role, bypasses RLS) can write. Add read policies only where the
client reads tables directly — and prefer routing reads through functions too, so the initial policy
count is ~zero. This is the whole Day-1 RLS deliverable; per-table policy work is deferred
indefinitely unless a direct-read hot path (e.g. realtime on `hexes` for the second screen) needs a
`select` policy — that one is one line:
`create policy hexes_read on hexes for select using (true);`.

---

## 4. Movement catalogue seed — then frozen

`supabase/migrations/0002_movements.sql` — the fifteen movements from the
[§4 variation tree](requirements.md), with ids, families, tiers, and difficulty multipliers exactly
as tabled (`squat 1.0`, `pull_up 1.8`, …). **B owns id/tier/multiplier; A owns the joint-angle
config inside `joint_config`** ([roles.md §5](roles.md)) — seed `joint_config` from the Day-2
starting values in [api-contract.md §evidence](api-contract.md) and let A's tuned constants land as
updates to that column only.

Frozen after today: changing a multiplier after Day 1 needs standup.

---

## 5. Auth — guest first, social deferred

Enable **anonymous sign-in** in the Supabase dashboard (Auth → Providers). That is the entire Day-1
auth deliverable:

- Satisfies the real requirement in A1 — a judge never hits a signup wall.
- `supabase_flutter`: `signInAnonymously()` → JWT → every function call carries it.
- `profiles` row created on first sign-in via a `handle_new_user()` trigger on `auth.users` (part of
  `0001_core.sql`).
- Device binding (A3): a `POST /devices` upsert inside the session-start function — no separate
  flow.

**Deferred to Day 5, or cut:** Google/Apple OAuth. It's demo-invisible. If added, it's dashboard
config + `signInWithOAuth` — no schema change, so deferring costs nothing structurally.

---

## 6. Edge Function scaffold — stubs on real routes

**The key move: stubs are not client-side fakes. They are the real functions, deployed at the real
URLs, behind the real auth, returning canned JSON.** C wires up URLs, auth headers, and
deserialization on Day 1; the Day-3 "swap" is then a data-source flip inside each function, not a
client rewrite.

```
supabase/functions/
  _shared/
    auth.ts          verify JWT, extract user id
    responses.ts     json(), error(), CORS headers
    stubs/           one canned-payload module per endpoint  ← realistic, per Seam 2
  session-start/     POST  → { sessionId, serverStartMs, h3Index, spotContext, expiresAt }
  session-submit/    POST  → the C4 everything-response
  territory/         GET   ?bbox= → hex polygons+owner+power · /:h3 detail · /leaderboard
  spots/             GET nearby · POST create · POST /:id/checkin · GET /:id/board
  me/                GET   → profile, level, lifetime score, unlocked tiers
  movements/         GET   → catalogue + unlocked state (this one can be live today — it's a seed-table read)
  challenges/        GET daily · POST claim   (stub through Day 5)
  attest/            POST  (stub until Day 6)
```

Each function starts as:

```ts
import { stub } from "../_shared/stubs/session-submit.ts";
const LIVE = Deno.env.get("LIVE_ENDPOINTS")?.includes("session-submit");

serve(async (req) => {
  const user = await requireUser(req); // real auth from day one
  if (!LIVE) return json(stub(user)); // Day 1–2
  return json(await handleSubmit(req, user)); // lands Day 2–3, route by route
});
```

Endpoints go live **one at a time** by flipping `LIVE_ENDPOINTS` — no big-bang swap, and a
regression on Day 3 can be rolled back per-route in seconds.

**"Realistic" is a contract term** ([roles.md §4 Seam 2](roles.md)): stub payloads carry populated
boards, contested hexes, a plausible unlock, a non-empty PR list. The stub for
`GET /territory/hexes` returns ~30 real res-8 polygons around a hardcoded venue coordinate so C's
map work is honest about geometry from Day 1.

---

## 7. Evidence fixtures (B-24)

`test/server/fixtures/` — 3–4 hand-authored `evidence.json` files in the frozen shape from
[api-contract.md §evidence](api-contract.md):

1. `squat_20_clean.json` — 20 good reps, the happy path
2. `pullup_10_kip.json` — high `hipDriftNorm`, exercises the B18 penalty
3. `plank_60s_sag.json` — `holdSegments` with an out-of-form gap
4. `squat_replay_bad_clock.json` — timeline exceeding the session window, must be rejected (I3)

These are what B's Day-2 scoring service is built and tested against — **B's Day 2 does not wait on
A's Day 2** ([roles.md §4 Seam 1](roles.md)). They double later as the cross-language golden tests:
the same fixtures run through A's Dart pipeline and B's TS scorer must produce identical
`romScore`/`formFactor`/`RepScore`.

---

## 8. Dart model types

`lib/models/` — plain Dart classes with `fromJson`/`toJson` mirroring every stub payload and the
Evidence shape. Hand-written (codegen tooling is not worth setting up this week); the fixtures in
step 7 serve as the round-trip tests: `Evidence.fromJson(fixture).toJson() == fixture`.

B owns this directory ([roles.md §3](roles.md)); it is the typed contract C and A import.

---

## 9. Env + keys

- `supabase/.env` for function secrets, `.env.local` in Flutter for the project URL + anon key. Both
  in `.gitignore`.
- B distributes keys directly to A and C ([roles.md §5](roles.md)). **Nobody commits keys.**
- `LIVE_ENDPOINTS` is the only backend feature flag; the client has none for this.

---

## Day-1 definition of done (the gate, restated)

- [ ] `supabase start` + linked hosted project; migrations applied to both
- [ ] h3 decision recorded (extension or h3-js) in `0001_core.sql`
- [ ] Every table above exists; RLS enabled everywhere with zero write policies
- [ ] Movement catalogue seeded and declared frozen in standup
- [ ] Anonymous sign-in returns a JWT; `handle_new_user` creates a profile
- [ ] **Every endpoint in the register answers with realistic canned JSON at its real URL, behind
      real auth** — C can call all of them from the app
- [ ] Evidence fixtures exist; `curl` of `squat_20_clean.json` at `session-submit` returns the
      stubbed C4 response
- [ ] `lib/models/` compiles and round-trips the fixtures
- [ ] Keys distributed; nothing sensitive in git

If time runs short, the cut order **within Day 1** is: Dart models → fixtures (both slip to Day 2
morning). The stubs and schema do not slip — they are the two things Day 2 of all three tracks
stands on.
