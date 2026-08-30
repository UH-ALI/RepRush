# RepRush — Roles & Ownership

**Companion to [requirements.md](requirements.md).** That document says *what* gets built. This one says **who builds it, where it lives, and who owns the seams between them.**

> Three people, seven days. The failure mode is not "we couldn't build it" — it's *"two of us spent Tuesday waiting on the third."* Everything below exists to make that impossible.

---

## 0. The one rule

**Every file, table, endpoint, and screen has exactly one owner.**

- You may **read** anything. You may **run** anything.
- You may **edit** only what you own. Need a change outside your track? Ask the owner — they either make it in five minutes or hand you the file for the day. Both are fine. Silently editing across the boundary is not.
- Where two tracks genuinely meet, the seam is a **contract** (§4), and the contract has an owner too.

This costs about ten minutes a day and buys you the ability to merge without reading each other's diffs.

---

## 1. The three roles

| Track | Owner | Mandate — one line | Accountable for | Failure looks like |
|---|---|---|---|---|
| **A — Capture** | **Dev 1** — *name:* | Make the phone count reps correctly | **The Day-2 ±1 gate.** Calls go/no-go alone | The counter is wrong on stage and nothing else matters |
| **B — Core** | **Dev 2** — *name:* | Be the referee: schema, scoring, territory, integrity | **The Day-1 API contract** and every number the server asserts | C is blocked, or a judge asks "what stops me faking this" and there's no answer |
| **C — Surface** | **Dev 3** — *name:* | Everything the judge sees, and the demo itself | **The Day-7 rehearsal** and demo mode | It works, and it looks like a hackathon project |

**A is the critical path.** Whoever finishes their day's list first pulls the next item off Track A. This is a standing rule, not a favour.

---

## 2. Deliverable register — who creates what

### Track A — Dev 1 · Capture

**A's whole world is one function signature: landmarks in, Evidence out.** Nothing in this track needs to know that hexes, spots, decay, or boards exist — see §4 Seam 1.

| # | Artifact | Lives in | Reqs | Due |
|---|---|---|---|---|
| A-1 | Android `minSdkVersion` bump, camera + location permissions in manifest | `android/app/build.gradle`, `AndroidManifest.xml` | §8 | **Day 1, first 2 h** |
| A-2 | iOS deployment target bump, camera/location usage strings, ML Kit pods | `ios/Podfile`, `ios/Runner/Info.plist` | §8 | **Day 1, first 2 h** |
| A-3 | Camera stream → `InputImage` adapter (rotation, YUV420/BGRA, plane layout) | `capture/camera/input_image.dart` | B1, §8 risk | Day 1 |
| A-4 | Pose inference service — ML Kit `base` model, stream mode, fps governor with 10 fps floor | `capture/camera/pose_service.dart` | B1 | Day 1 |
| A-17 | **Landmark trace recorder** — debug flag dumping the raw landmark stream plus timestamps to JSON | `capture/camera/trace_recorder.dart` | A-15 | **Day 1, the moment landmarks render** |
| A-5 | Signal conditioning — joint-angle and ratio math, higher-confidence-side selection, **EMA/one-euro smoothing upstream of the state machine (mandatory, not polish)** | `capture/pipeline/signal.dart` | B7, I8 | Day 2 |
| A-6 | **Rep state machine** — `REST`↔`PEAK`, two-threshold hysteresis, direction-aware | `capture/pipeline/rep_machine.dart` | B3 | Day 2 |
| A-7 | Movement configs from the threshold table in [api-contract.md §evidence](api-contract.md#evidence): squat → **push-up → pull-up** → plank → jumping jack. **A tunes the constants and reports them back to that table** | `capture/pipeline/configs/` | B10, B16 | Day 2–3 |
| A-8 | Hold capture — form-gated timer, in-form / out-of-form indicator | `capture/pipeline/hold_timer.dart` | B12 | Day 3 |
| A-13 | Swing/kip measurement — horizontal hip drift per rep, **normalised against shoulder width** (`hipDriftNorm`, never pixels) | `capture/pipeline/swing.dart` | B18 | Day 5 |
| A-14 | **Evidence assembly** — `RepEvent` + downsampled `PoseTrace` (~5 fps) into the frozen Evidence shape | `capture/pipeline/evidence.dart` | I1, I8, §4 Seam 1 | **Day 2** |
| A-18 | **Evidence file dump** — write a complete `evidence.json` to disk from any session, so B can `curl` it with no phone in the loop | `capture/pipeline/evidence.dart` | §4 Seam 1 | Day 2 |
| A-9 | Framing check + 3-2-1 countdown | `capture/ui/framing_check.dart` | B4 | Day 2 |
| A-19 | **Calibration capture during the countdown** — rest-pose signal, torso length, shoulder width. Thresholds become relative to the athlete's own start pose, which is the main defence against camera-angle drift and body proportions | `capture/pipeline/calibration.dart` | B4, B17 | **Day 2** |
| A-10 | Capture HUD — skeleton overlay, rep count, ROM/depth indicator, **three-state live feedback** (green = valid, amber = actionable correction such as "go lower", red = tracking lost / out of frame / completed invalid attempt), every state with visible signal plus audio cue (`CustomPainter`) | `capture/ui/capture_hud.dart` | B5, B6 | Day 3 |
| A-12 | Per-movement camera placement cards — illustration plus one line | `capture/ui/placement_card.dart` | B11, B17 | Day 3 |
| A-11 | **Audio rep count and form cues** (`flutter_tts`) | `capture/ui/audio/` | B5, N9 | Day 5 |
| A-15 | **Trace fixture corpus + replay suite** — 20-rep sets across 3 body types and 2 lighting conditions, recorded once via A-17, hand-labelled, replayed through `pipeline/` in a plain `dart test` asserting ±1 | `test/capture/fixtures/`, `test/capture/replay_test.dart` | §6-B acceptance | **Day 2 gate**, then standing |
| A-16 | **10-minute thermal + battery test on the demo phone**, written result | `docs/thermal-test.md` | N5 | Day 5 |

**A does not build:** any screen outside the capture flow, any API call, any scoring arithmetic. A produces *evidence*; B decides what it's worth.

**The purity rule:** `capture/pipeline/` imports no Flutter, no plugins, no `dart:ui` — landmarks in, Evidence out, plain Dart. That constraint is what makes A-15 a sub-second test run instead of a rebuild and twenty reps. If something in `pipeline/` needs a widget or a plugin, it belongs in `camera/` or `ui/` instead.

### Track B — Dev 2 · Core

| # | Artifact | Lives in | Reqs | Due |
|---|---|---|---|---|
| B-1 | Postgres schema + PostGIS + H3 extension; RLS policies on every table | `supabase/migrations/` | §3 | Day 1 |
| B-2 | Auth: Apple/Google plus a guest path, device binding | `supabase/migrations/`, `lib/core/auth/` | A1, A3 | Day 1 |
| B-3 | **Published API contract — shared types plus stubbed endpoints returning realistic fake data** | `docs/api-contract.md`, `lib/models/` | §9 dep 1 | **Day 1, end of day — hard** |
| B-24 | **The Evidence schema** — the interface all three layers meet at (§4 Seam 1). **A draft exists at [api-contract.md §evidence](api-contract.md#evidence); B owns it, reviews it, and tunes it.** Plus 3–4 hand-authored `evidence.json` fixtures B can score before A produces a real one | `docs/api-contract.md` §evidence, `test/server/fixtures/` | I1, §4 Seam 1 | **Day 1, end of day — hard, then frozen** |
| B-4 | Movement catalogue seeded from §4 — ids, families, tiers, difficulty multipliers | `supabase/migrations/*_movements.sql` | §4 | **Day 1 — then frozen** |
| B-5 | Scoring service — server-side recompute of `romScore` and `formFactor` ([formulas](api-contract.md#evidence)), then `reps × difficulty × formFactor × tempoFactor`, hold conversion, per-set and per-day caps. **Built against B-24's fixtures — B's Day 2 does not depend on A's Day 2 landing** | `supabase/functions/score/` | §4, I1 | Day 2 |
| B-6 | Append-only score ledger plus the void/recompute path | `supabase/migrations/`, `supabase/functions/` | §3 rule 1, I12 | Day 2 |
| B-7 | **One-shot sessions**: `/session/start` issues the id (plus active `movementConfigVersion`) and records the session-start location/spot context; submit consumes it, 4 h expiry. Server rejects submit on `movementConfigVersion` mismatch and on `SESSION_CONTEXT_MISMATCH` (Evidence location/spot ≠ session-start context); territory resolution always uses the server-recorded start context | `supabase/functions/session-start/` | I2 | **Day 2 — first draft, not later** |
| B-8 | **Wall-clock containment** — server-recorded start/submit, claimed timeline must fit inside it | `supabase/functions/session-submit/` | I3 | Day 2 |
| B-9 | Claim + capture + **72 h half-life decay, computed lazily on read** — written once, shared by both scales | `supabase/functions/territory/` | D2, D3, §5 | Day 3 |
| B-10 | Hex resolution: H3 res-8 indices and boundary polygons computed **server-side**, shipped as plain coordinates | `supabase/functions/hexes/` | §8 open-1 | Day 3 |
| B-11 | **Single-round-trip submit response** — XP, hex result, spot result, rank change, unlocks, PRs | `supabase/functions/session-submit/` | C4 | Day 3 |
| B-12 | Spots: discovery, proximity check-in, capture, **spot→hex power bonus**, 3-distinct-user verification | `supabase/functions/spots/` | E1–E3, E6, D5 | Day 4 |
| B-13 | Standing boards — power / PR count / achievement points tabs | `supabase/functions/boards/` | E4 | Day 4 |
| B-14 | PR detection per movement — max reps, max hold, hardest tier | `supabase/functions/session-submit/` | E5 | Day 4 |
| B-15 | XP curve `100 × n^1.5`, levels, streak, **tier unlocks at 50 verified reps** | `supabase/functions/progression/` | F1–F3 | Day 5 |
| B-16 | ~15 seeded achievements, evaluated server-side on ledger write | `supabase/seed/achievements.sql` | F4 | Day 5 |
| B-17 | Daily challenge generator plus the explicit claim step | `supabase/functions/challenges/` | G1, G3 | Day 5 |
| B-18 | Notification backend — hex lost, spot lost, passed on a board | `supabase/functions/notify/` | H1, D8, E7 | Day 5 |
| B-19 | **Device attestation** — Play Integrity / App Attest verified in an Edge Function, token bound to the session id | `supabase/functions/attest/` | I5 | Day 6 |
| B-20 | Plausibility validators (async): cadence floor, tempo variance, fatigue drift, teleport check, mock-location rejection | `supabase/functions/validators/` | I6–I9 | Day 6 |
| B-25 | **Trace/summary consistency check** — each rep's claimed extreme must agree with `trace.primary` over its own window, and trace threshold crossings must be within ±1 of the rep count. Forces a forger to fake two representations coherently | `supabase/functions/validators/` | I1, I8 | Day 6 |
| B-21 | Rate limits plus the shadow-flag mechanism (**never hard-ban during a hackathon**) | `supabase/functions/` | I11, I13 | Day 6 |
| B-22 | **Seed script** — ~30 users, populated hexes and spots around the venue, a competitive board | `supabase/seed/demo.sql` | J1 | Day 6 |
| B-23 | **One-command reset to a clean demo state** | `scripts/reset-demo.sh` | J3 | Day 6 |
| B-26 | **Demo-board routing (server-side)** — sessions from allowlisted demo accounts route to the isolated demo board. Mocked GPS is rejected for production accounts; a demo account is permitted only the fixed server-authorized demo location and seeded Spot, substituted server-side. Authorization is never derived from Evidence fields, build flags, or client-side toggles | `supabase/functions/`, server config | J7 | Day 6 |

**B does not build:** any widget. B's deliverable to C is always an endpoint plus a typed model.

### Track C — Dev 3 · Surface

| # | Artifact | Lives in | Reqs | Due |
|---|---|---|---|---|
| C-1 | App shell, router, navigation | `lib/app/` | — | Day 1 |
| C-2 | Design system — tokens, typography, ownership colours that **never carry meaning alone** | `lib/app/theme/` | N9 | Day 1 |
| C-3 | State-management convention, decided and written down | `docs/api-contract.md` §state, `lib/core/` | §8 | **Day 1 — with A and B in the room** |
| C-4 | Map screen — `flutter_map`, hex polygons by owner, spot pins overlaid, 500+ cells without jank | `lib/features/territory/ui/map_screen.dart` | D1, N2 | Day 1 (fake) → Day 3 (live) |
| C-5 | Hex detail sheet — owner, power, your power, spots inside, recent flips | `lib/features/territory/ui/hex_sheet.dart` | D6 | Day 2 |
| C-6 | Session summary screen — reps, RepScore, form grade, PR, tier progress, manual ± correction (**local-only UI annotation — never transmitted**) | `lib/features/session/ui/summary_screen.dart` | B9, B8 | Day 2 |
| C-7 | Profile and progression UI — XP, level, streak, the variation tree | `lib/features/progression/ui/` | A2, F1–F3 | Day 4 |
| C-8 | Spot screens — discovery, check-in, create-a-spot, detail, standing board tabs | `lib/features/spots/ui/` | E1–E4 | Day 4 |
| C-9 | Territory leaderboard | `lib/features/territory/ui/leaderboard.dart` | D7 | Day 4 |
| C-10 | Celebration moments — PR, level-up, tier unlock | `lib/features/progression/ui/moments/` | B15, E5, F1 | Day 5 |
| C-11 | Push notification handling plus permission priming screens | `lib/features/notifications/`, `lib/app/priming/` | H1, N8 | Day 5 |
| C-12 | Empty states, error states, **the GPS-accuracy explanation** (D4 must read as a reason, not a failure) | `lib/shared/states/` | D4, N11 | Day 5 |
| C-13 | Offline submit queue UI plus flush-on-reconnect | `lib/features/session/queue/` | C5, N11 | Day 5 |
| C-14 | **Mock-location build flag** — may support local staging UI, but must not choose or influence the server-side demo territory context: the server permits only a fixed server-authorized demo location and seeded Spot against the isolated demo board (B-26/J7), and mocked-location submissions from production accounts are rejected | `lib/core/demo_mode.dart` | J2 | Day 6 |
| C-15 | **Written demo script** | `docs/demo-script.md` | J4 | Day 6 |
| C-16 | Crash and error reporting visible to the team on demo day | `lib/core/telemetry/` | J5 | Day 6 |
| C-17 | Runs the rehearsals — three clean run-throughs minimum | — | J4 | **Day 7** |

**C does not build:** anything inside `features/capture/`, and no server logic. C consumes A's capture flow as a black box and B's API as typed models.

---

## 3. Repo layout — the ownership map

Treat this as CODEOWNERS. If a path isn't listed, it belongs to whoever owns the parent directory.

```
android/                          A      platform config, permissions
ios/                              A      deployment target, Info.plist, pods
lib/
  main.dart                       C
  app/                            C      router, theme, tokens, priming screens
  core/
    auth/                         B
    api/                          B      generated clients, error mapping
    demo_mode.dart                C
    telemetry/                    C
  models/                         B      shared types — generated from the contract
  features/
    capture/                      A      the isolated problem: camera → Evidence
      camera/                     A      frames → landmarks. Plugin plumbing, ML Kit, trace recorder
      pipeline/                   A      landmarks → Evidence. PURE DART — no Flutter, no plugins
      ui/                         A      HUD, framing check, placement cards, audio
    session/
      queue/                      C      offline queue and its UI
      ui/                         C      summary screen
    territory/
      data/                       B
      ui/                         C
    spots/
      data/                       B
      ui/                         C
    progression/
      data/                       B
      ui/                         C
    notifications/                C
  shared/                         C      reusable widgets, empty and error states
supabase/
  migrations/                     B
  functions/                      B
  seed/                           B
scripts/                          B      reset-demo, seeding
test/
  capture/                        A      replay suite
    fixtures/                     A      recorded landmark traces, hand-labelled
  server/                         B
    fixtures/                     B      hand-authored evidence.json
  widget/                         C
docs/
  requirements.md                 shared — edits announced in standup
  roles.md                        shared
  api-contract.md                 B
    §evidence                     B      the shape. A reports tuned constants back
    §endpoints                    B
    §state                        C      the one section C owns in B's file
  demo-script.md                  C
  thermal-test.md                 A
```

**The pattern:** inside every feature, `data/` is B's and `ui/` is C's. `capture/` is the one exception — it is A's top to bottom, because the camera pipeline and the HUD that draws it are the same problem.

**`capture/pipeline/` is the load-bearing directory in this repo.** It is the entire camera→Evidence problem, it is where the Day-2 gate is won or lost, and it is pure Dart on purpose: no Flutter imports, no plugins, no `dart:ui`. Landmarks in, Evidence out. That purity is not tidiness — it is what lets A-15 replay a hundred recorded sets in a second instead of rebuilding the app and doing twenty pull-ups.

---

## 4. The seams — where two people meet

Three seams, three contracts. Each has an owner, a consumer, and a freeze date. **Nothing outside these three lists crosses a track boundary.**

### Seam 1 · Evidence — the interface all three layers meet at

**This is not just the A→B payload. It is the thing that decomposes the product into three independent problems.** Get it right and nobody is ever blocked; get it late and all three tracks quietly couple to each other.

```
  camera    →  Evidence           Track A   landmarks in, Evidence out. The isolated problem
  Evidence  →  backend            Track B   schema, scoring, ledger, territory. The referee
  Evidence  →  map, UI, features  Track C   consumes it as a typed model, never produces it
```

Read it as a hub, not a chain. **Evidence is the only thing that crosses a track boundary in the capture path**, which is what buys each track its independence:

- **A never touches the rest of the system.** No hexes, no spots, no decay, no boards, no API calls. A's entire contract with the world is one object shape.
- **B builds scoring before A produces anything real.** Hand-author `evidence.json` (B-24), run it through the scoring service, check the arithmetic. B's Day 2 does not wait on A's Day 2.
- **The Day-2 fallback costs nothing downstream.** If camera counting fails the gate, the camera is demoted to a form-check showpiece and the demo ships whichever movements pass — Slice 1 (squat) first. The Evidence → server → ledger loop is not coupled to any particular movement or input path, so B and C never notice.

**B owns the shape; A owns filling it. Frozen end of Day 1**, alongside the API contract — it has to exist before anyone writes code against it, and every track writes code against it on Day 2.

**Evidence is a file, not just a POST body.** A can dump `evidence.json` to disk (A-18) and B can `curl` it straight at the submit endpoint. So A tests with no backend, B tests with no phone, and Day 3 stops being a scary integration day — you have been integrating via files since Day 2.

**The shape lives in exactly one place: [`api-contract.md` §evidence](api-contract.md#evidence).** Not duplicated here — two copies of an interface drift by Day 4. That document defines the three granularities (set / rep / trace), the rep state machine, the per-movement threshold table, the `romScore` and `formFactor` formulas, and what the server can and cannot verify. In summary:

```
set    movement, timing, capture quality, calibration      once per set
rep    the numbers that made it a rep                      on each rep transition
trace  ~5 Hz downsample of the primary signal              continuously
```

Three things in that document are load-bearing enough to restate here:

- **ROM is enforced twice, in different ways.** The threshold is the *gate* — a shallow rep never changes state, so it is never counted. Depth beyond the threshold is the *grade*, via `romScore`. Conflating these is what makes the design read as arbitrary.
- **No pixel measurement may appear in a rep record.** Every distance field is normalised against a calibration scale reference (`hipDriftNorm`, not `hipDisplacementPx`) or it means nothing across camera distances.
- **The trace is not padding.** It is what lets the server cross-check each rep's claimed extreme against an independent time series, so a forger has to fake two representations coherently.

**Rules on this seam:**

- **The client never sends a score.** It sends evidence. If a PR adds a `score` field to this payload, reject it (I1).
- **B designs for what the referee needs, not what the camera finds easy to emit.** The shape has to carry enough for scoring *and* for the async validators (I6–I9) — cadence, tempo variance, fatigue drift. If A designs it around convenience, you find out on Day 6 that a validator is unbuildable.
- A adding a *new signal* (say hip displacement for B18) is an additive change — tell B, ship it, B ignores it until they use it.
- A *removing or renaming* a field after Day 1 needs B's agreement in standup. No changes at all after Day 5.
- **Isolation is not validation.** A can develop against recorded traces alone, but "does it count 20 reps correctly?" still needs a human doing 20 reps under real lighting. That gap is exactly what A-15's fixture corpus exists to narrow — record the sets once, replay them forever.

### Seam 2 · B → C — the API contract

**This is the dependency that decides whether the week works.** C cannot start real work without it, and C must never be blocked on B's real logic.

- **B publishes `docs/api-contract.md` plus stubbed endpoints returning realistic fake data by end of Day 1 — before writing a line of real logic.**
- C builds **every screen against stubs** through Day 2 and swaps to live data on Day 3.
- "Realistic" means populated boards, contested hexes, a plausible unlock, a non-empty PR list. Stubs that return empty arrays teach C nothing about layout.

Endpoint register — B creates, C consumes:

| Endpoint | Returns | Consumed by |
|---|---|---|
| `POST /session/start` | session id, server start time, **`movementConfigVersion`**, hex index, spot context, expiry | A (starts it), C (shows context) |
| `POST /session/submit` | **everything in one response** — XP, level, hex result, spot result, rank change, unlocks, PRs, achievements (C4). **Rejects `movementConfigVersion` mismatch and `SESSION_CONTEXT_MISMATCH`** (territory always resolves from the session-start context) | C-6 summary screen |
| `GET /territory/hexes?bbox=` | polygons plus owner and power (plain coords — no H3 on the client) | C-4 map |
| `GET /territory/hex/:h3` | owner, power, your power, spots inside, recent flips | C-5 sheet |
| `GET /territory/leaderboard` | hexes held, total area | C-9 |
| `GET /spots/nearby?lat=&lng=` | spots plus holder and verified flag | C-8 |
| `POST /spots` | creates an **unverified** spot | C-8 |
| `POST /spots/:id/checkin` | check-in result or proximity rejection | C-8 |
| `GET /spots/:id/board?tab=` | power / PR count / achievement points | C-8 |
| `GET /me` | handle, avatar, level, lifetime score, home spot, unlocked tiers | C-7 |
| `GET /movements` | catalogue plus unlocked state and tier progress | A (configs), C-7 (tree) |
| `GET /challenges/daily` · `POST /challenges/daily/claim` | progress and claim | C |
| `POST /devices/attest` | attestation binding (Day 6) | A |

**C4 is one round trip on purpose.** If C finds itself making five calls to render the summary screen, that's a bug in B's response — not a workaround for C to build around.

### Seam 3 · A ↔ C — the capture flow embed

- **A owns the capture screen** end to end: framing check, countdown, HUD, audio, hold timer.
- **C owns everything either side of it**: how you get in (start-session flow, movement picker, spot context) and what happens on exit (summary screen C-6).
- A hands C **one entry point and one result object**. C never reaches into pose state; A never navigates anywhere.
- **Design tokens flow one way:** A uses C's tokens (`lib/app/theme/`) for the HUD, so capture doesn't look like a different app. If A needs a token that doesn't exist, C adds it.

---

## 5. Shared artifacts — assigned, so they don't rot

The things that belong to "the team" are the things nobody maintains. Each has one name against it.

| Artifact | Owner | Rule |
|---|---|---|
| **The Evidence schema** — [api-contract.md §evidence](api-contract.md#evidence) | **B** | **The most load-bearing artifact in the repo — frozen end of Day 1.** All three layers meet here. Additive changes by announcement; renames need standup; nothing at all after Day 5 |
| **Movement threshold constants** — the table in §evidence | **A**, inside B's shape | B owns the *fields*; **A owns the numbers**, because only A can tune them against real sets. A reports tuned values back into the table on Day 2–3 so B's fixtures stay realistic |
| **Movement catalogue and difficulty multipliers** (§4) | **B** | **Frozen Day 1.** A owns the joint-angle config *inside* each movement; B owns its id, tier, and multiplier. A changing a threshold is fine; A changing `pull_up` from 1.8 needs B |
| Scoring constants — caps, curves, hold conversion | **B** | Sanity-checked against a real set on Day 4 (§4). If plank is the best points-per-minute in the game, B fixes it that day |
| Design tokens | **C** | A and C both consume. Additions on request, same day |
| State-management convention | **C**, decided Day 1 with all three | With three devs, an unstated convention diverges by Day 3 |
| `docs/requirements.md` | **Shared** | Edits announced in standup — it's the spec everyone reasons from |
| Supabase project keys and env | **B** | B distributes. Nobody commits keys |
| **The demo phone** | **A through Day 6**, then whoever presents | One phone. Test on it daily, never on a simulator |
| CI / build pipeline | **C** | Lowest priority — a green build matters less than a working phone this week |
| **Pull-up bar for demo day** (J6) | **C** — resolve by **Day 5** | Venue rig, doorway bar, or a pre-recorded set filmed on the real app. It's a logistics problem, so it goes to the person who owns the demo |

---

## 6. Decision rights

Ambiguity about who decides costs more than any wrong decision this week.

| Decision | Decided by | Notes |
|---|---|---|
| **Day-2 go/no-go on rep accuracy** | **A, alone** | Others advise. A calls it at the gate and the fallback triggers immediately — don't let it drift |
| What a set is worth | **B** | The server is the referee. Nobody argues scoring in a PR |
| Whether a session is flagged | **B** | Shadow-flag only (I13) |
| What the judge sees, and in what order | **C** | Including the demo script and the running order |
| The cut list when behind | **C proposes, all three agree in standup** | Fixed order: challenges → achievements → higher tiers → decay → notifications. **Never cut a scale** |
| Anything touching two tracks | **Standup, 15 minutes, decided that morning** | If it can't be decided in 15 minutes, the owner of the more-blocked track decides |

---

## 7. Day-by-day ownership grid

| Day | A — Capture | B — Core | C — Surface | Gate |
|---|---|---|---|---|
| **1** | Platform config (2 h), then **camera → `InputImage` → landmarks on the real phone. Nothing else** — then the trace recorder (A-17), which is 20 lines once landmarks render | Schema and auth, **publish the Evidence schema and the API contract plus stubs by EOD** | Shell, nav, tokens, map with fake ownership | Keypoints on a real phone, **Evidence frozen**, C calling every endpoint |
| **2** | Squat state machine to **±1**, calibration capture, **tuned thresholds reported back into §evidence**. Record the fixture corpus while people are in the room — sets get performed **once** | Scoring and ledger **against hand-authored evidence files**, **one-shot sessions and wall-clock (I2–I3)** | Boards, profile, hex and spot detail, summary — all on stubs | **±1 rep on a 20-rep set**, replayable from fixtures |
| **3** | **push-up → pull-up** → plank → jumping jack. *Jumping jack may slip; pull-up may not* | Claim and decay for **both** scales, single-round-trip submit | Rip out stubs, wire live APIs, real ownership on the map | A real workout flips a real hex, no mocks |
| **4** | Form scoring, summary, PR and unlock moments. *CV work largely done — A now absorbs work off whichever track is behind* | Spots end to end, boards, PRs, spot→hex bonus, 3-user verification | Spot screens, progression UI | Both scales end to end |
| **5** | Audio cues, capture polish, **thermal test** | XP, unlocks, achievements, challenges, notifications | Moments, push, empty and error states | Feature complete |
| **6** | Capture fixes under **venue lighting** | Attestation, validators, rate limits, seed, reset | Demo mode, seeded venue data, polish | **Freeze 12:00.** Bugs only after |
| **7** | Holds the phone, performs | Watches server logs | Drives map and boards on the second screen | Three clean run-throughs |

**Standing rules that bind all three:** 15-minute standup and 15-minute integration check, start and end of day. After Day 6 noon, **no solo merges to main** — two sets of eyes on every change.

---

## 8. Reassignment rules — what happens when

| Trigger | Reassignment |
|---|---|
| **Day-2 gate fails** | The camera is demoted to a "form check" showpiece and the demo ships with whichever movements pass the gate — Slice 1 (squat) first. **There is no manual scoring path** — self-reported activity is diary-only with zero competitive consequences. **B and C are structurally unaffected**: the Evidence → server → ledger loop is not coupled to any particular movement, so only the capture UI changes. A then **becomes a second Surface dev under C's direction**. Decide at the gate; don't drift |
| **Camera → `InputImage` not solved by end of Day 1** | Escalate that evening. All three on it Day 2 morning if needed. **Do not let it bleed silently into Day 2** |
| **A finishes early (Day 4+)** | A takes work off whichever track is behind — C first by default, since surface work is the most parallelisable |
| **B is behind on Day 3** | C keeps building against stubs rather than idling. Stubs are the pressure valve — that's what they're for |
| **C is behind on Day 5** | Cut in the fixed order (§6). A absorbs UI work |
| **Anyone blocked more than 2 h** | Raise it immediately, not at the next standup. Two devs idle waiting on the third is the most expensive failure mode of the week |

---

## 9. Demo day — Day 7

| Role | Person | Job |
|---|---|---|
| **Performer** | **A** | Holds the phone and does the reps. A built the counter, so A knows exactly how to frame the shot |
| **Ops** | **B** | Watches server logs live. If a submission fails, B knows why before anyone asks |
| **Driver and narrator** | **C** | Runs the map and boards on the second screen, drives the script |

**Zero planned coding.** A known-good signed build stays installed on the demo phone from the Day-6 freeze — there is no OTA safety net, so a Day-7 fix means a full rebuild and reinstall.

---

## 10. Per-track definition of done

**A is done when** a 20-rep set counts within ±1 across 3 body types and 2 lighting conditions, the fixture replay suite is green for all five v1 movements, they work on the demo phone, audio calls every rep, and a 10-minute session doesn't throttle the device.

**B is done when** the client *cannot* submit a score at all — only evidence — every board recomputes from the ledger, a replayed submission is rejected structurally, and one command resets the venue to a clean, populated demo state.

**C is done when** the demo runs three times in a row on the venue's network with no mocked screens, and someone who has never seen the app understands the map in five seconds.

**The team is done when** §11 of [requirements.md](requirements.md) runs end to end, three times, on the demo phone.
