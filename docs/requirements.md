# RepRush — Requirements Plan

**Build window:** ~7 days · **Team:** 3 people · **Client:** Flutter · **Discipline:** calisthenics only · **Rep tracking:** camera + on-device pose detection (ML Kit)

> **RepRush is a territory game you play with your body.** No equipment, no gym membership, no honour system — the camera is the referee.

---

## 0. The read

Two game loops are competing for one week of build time. The honest framing:

- **The rep counter is the product's credibility.** If a judge does 10 squats and the number is wrong, nothing else matters.
- **Territory is the product's story.** It's what makes this a *platform* and not another workout logger.
- **Progression is glue.** It should exist, but calisthenics hands you most of it for free — see the variation tree in §4.

**Why calisthenics only.** It isn't a scope cut, it's what makes the two loops one product:

1. **Barbell training is location-fixed; territory requires movement.** You lift at one gym, in one hex, standing still. A barbell user could never meaningfully play the territory game. Calisthenics is inherently mobile — parks, plazas, bars, hotel rooms — which is exactly the substrate territory capture needs.
2. **A camera can't see what's on a bar, but it can see everything in calisthenics.** Every scored movement is fully verifiable, which deletes an entire class of cheating and every honour-system mechanic that would otherwise be needed to contain it.
3. **The privacy claim becomes absolute.** No video ever leaves the device. No exceptions, no asterisk.
4. **The sport already invented the progression system.** Knee push-up → push-up → diamond → archer → one-arm is a skill tree you inherit rather than design.
5. **Zero equipment means a judge can try it on stage**, in the next sixty seconds.

Gyms don't disappear — they become one kind of **Spot** (§5), and spots are capturable territory. Gym rivalry survives intact; it just stops being a separate system bolted onto the side.

Everything below is scoped so that on Day 7 you can do one uninterrupted take: squat in front of the phone → score lands → the hex you're standing in flips to your colour → you take the spot you're at → level up. No fake screens in that path.

**Priority key:** `MUST` ships or the demo dies · `SHOULD` ships if the core holds · `COULD` only with spare time · `WON'T` explicitly out of scope this week.

---

## 1. Scope decision (MoSCoW)

### MUST
- Auth + minimal profile
- Camera counter for **5 movements** — squat, push-up, **pull-up**, jumping jack, plank — with live on-screen and **audible** feedback. **Squat ships in Slice 1; the rest land in later slices** (*Scope sequencing* below)
- Workout session → server-validated score submission
- **Two territory scales:** H3 hexes (claim, hold, capture, decay) and Spots (capture by presence, with a standing board)
- Spots held contribute bonus power to their containing hex — the loops feed each other
- XP / level / streak
- **Variation tree**: harder movement tiers unlock through verified history, and score more
- Integrity floor: server recomputes every score; **one-shot, replay-proof sessions**; GPS and cadence plausibility
- Demo tooling — seed data and mock-location mode (§6-J)

### SHOULD
- Achievements (~15 seeded)
- Daily challenge
- Push notification when your hex or spot is taken
- Form-quality grade from pose confidence and range of motion
- Diary entry for unsupported movements (zero score — see B13)

### COULD
- Squad / crew ownership of spots
- Head-to-head rivalry duels
- Workout history charts, rest timer
- Spot-vs-spot aggregate standings

### WON'T (this week — say it out loud so nobody drifts)
- **Weighted or barbell training of any kind.** This is the defining constraint, not a limitation
- Wearables / HealthKit / Strava import
- Guaranteed iOS + Android parity (pick one demo device, test on *that phone*)
- Real-time multiplayer, friend graph, chat
- Payments, moderation tooling, appeals process
- Offline conflict resolution beyond a simple submit queue
- Automatic movement recognition (you pick the exercise; see B14)
- Self-reported activity as scoring input — diary entries are non-competitive history only (B13, DiaryEntry)

### Scope sequencing — slices

**Slice 1** is the whole product at one movement's width: **squat**, the complete Evidence → server → ledger loop, one claimed hex, **one minimal seeded Spot**, and the live-feedback system (green / amber / red). Everything else waits until that loop is proven end to end.

**Later slices**, in order: additional movements (push-up → pull-up → plank → jumping jack) · advanced Spot features (user creation, 3-user verification, standing boards) · integrity hardening (attestation, plausibility validators, rate limits) · progression depth (XP curve, variation-tree unlocks, achievements) · mission personalization.

---

## 2. Who it's for

| Persona | Wants | What hooks them |
|---|---|---|
| **The Street Athlete** | Owning the bar at their park, unlocking the muscle-up | Spot capture + variation tree |
| **The Roamer** | Covering ground, owning their neighbourhood | Hex territory |
| **The Beginner** | A reason to show up today, and a path that isn't intimidating | Streaks, daily challenge, tier-1 variations |
| **The Judge** | To understand the product in 90 seconds | The uninterrupted demo take |

The Judge is a real persona this week. §6-J exists entirely to serve them.

---

## 3. Domain model

- **User** — handle, avatar, level, lifetime score, home spot
- **Device** — bound to user; carries attestation state
- **Movement** — id, name, family, `tier`, `measurementType`, difficulty multiplier, joint-angle config, camera setup hint
- **MovementFamily** — the variation tree (§4): squat, push, hold, jump
- **UnlockedMovement** — user, movement, unlocked-at, qualifying session
- **WorkoutSession** — user, server-issued id, start/submit times, H3 index, spot (nullable), status
- **SetRecord** — session, movement, rep count *or* hold duration, form score, tempo stats, `scored` flag
- **RepEvent** — set, timestamp, peak/trough joint angle, mean keypoint confidence
- **PoseTrace** — set, downsampled angle time-series (~5 fps) used by the async validators
- **ScoreLedgerEntry** — append-only; user, session, points, reason, `voided` flag
- **Hex** — H3 index, owner, power, last-updated
- **Spot** — id, name, type (`calisthenics_park`, `gym`, `pull_up_bar`, `playground`, `custom`), location, containing H3 index, `verified` flag, owner
- **Claim** — polymorphic over hex and spot: target, user, power contributed, timestamp
- **PersonalRecord** — user, movement, metric (max reps / max hold / hardest tier), value, session
- **Achievement / UserAchievement**
- **ChallengeTemplate** — a challenge definition. Slice 1 ships exactly one static seeded daily template
- **MissionAssignment** — user, template, assigned-at, validity window
- **MissionProgress** — assignment, progress counted from verified, server-scored results only

**Four structural rules:**

1. **The score ledger is append-only and reversible.** Every point traces to a session. A flagged session is voided and leaderboards recompute — no destructive edits. This is what makes anti-cheat survivable.
2. **`RepEvent` and `PoseTrace` are stored, not just totals.** The server needs the raw stream to validate, and it gives you form replay for free if there's time.
3. **Hexes and spots share one claim mechanic.** Two scales, one set of rules — see §5.
4. **Missions may award capped XP only.** Territory power accrues only from verified RepScore earned in a session; missions never add territory power directly.

**Adaptive Missions are future architecture.** Slice 1 ships one static seeded daily challenge, identical for everyone. Personalized, rule-based mission generation starts only after the first full loop (capture → submit → score → territory) is stable. Missions count verified, server-scored results only — and per structural rule 4, they award capped XP, never territory power.

---

## 4. Movements and the scoring spine

One currency. Both loops and all progression read the same number. **No parallel currencies** — that's the requirement.

Because everything is calisthenics, **every scored set is camera-verified**. There is no declared data anywhere in the scoring path, no verification tiers, and no honour system. That single constraint is worth more to this design than any anti-cheat feature you could build.

### Two measurement types

| Type | Measured as | Example | Notes |
|---|---|---|---|
| `repBodyweight` | Repetitions | Squat, push-up | The core case |
| `holdTime` | Seconds under correct form | Plank, L-sit | Cheaper to build than reps — no state machine, just a form gate and a timer |

`distance` (running, cycling) is the obvious v2 and feeds territory beautifully. Not this week.

### The variation tree

Calisthenics progression is *harder movements*, not heavier ones. This is the progression system, the difficulty scale, and — usefully — an anti-cheat mechanism, all at once.

| Family | T1 | T2 | T3 | T4 |
|---|---|---|---|---|
| **Squat** | Assisted squat `0.7` | **Squat `1.0`** | Jump squat `1.5` | Pistol squat `2.4` |
| **Push** | Knee push-up `0.7` | **Push-up `1.0`** | Diamond `1.4` | Archer `2.0` |
| **Pull** | Dead hang `0.8` | **Pull-up `1.8`** | Wide-grip pull-up `2.2` | Muscle-up `3.0` |
| **Hold** | Wall sit `0.8` | **Plank `1.0`** | Side plank `1.3` | L-sit `2.2` |
| **Jump** | — | **Jumping jack `0.8`** | Burpee `2.2` | — |

Bold = the v1 five that must work by Day 3. Higher tiers are content, not engineering — each is a joint-angle config on machinery that already exists.

**T1 and T2 are unlocked by default; T3 and above unlock by demonstrating the tier below** — 50 verified reps at T*n* unlocks T*n+1*. So every user can score the canonical movement of every family from day one, while progression still has a real spine, beginners aren't shown a muscle-up on install, and — because unlocks require verified history — nobody arrives claiming pistol squats from a standing start.

Grip *width* is measurable (wrist separation against shoulder width), which is why wide-grip is its own tier. Grip *rotation* is not — ML Kit doesn't resolve forearm twist — so pull-ups and chin-ups are one movement at one difficulty. Don't build a distinction you can't verify.

### Scoring, per set

```
RepScore = reps × difficulty × formFactor × tempoFactor
```

| Term | Range | Source |
|---|---|---|
| `difficulty` | 0.7 – 2.4 | The variation tree above. **Freeze this table Day 1** |
| `formFactor` | 0.6 – 1.0 | Mean keypoint confidence × range-of-motion completeness |
| `tempoFactor` | 0.5 – 1.0 | Penalises implausibly fast or robotically uniform cadence |

Holds convert to the same unit — define **one rep-equivalent** and normalise:

```
holdTime:  RepScore = (seconds / 3) × difficulty × formFactor
```

A 60-second plank is worth ~20 rep-equivalents before difficulty. Sanity-check this against a real set on Day 4: if holds are trivially the best points-per-minute in the game, everyone will plank and nothing else.

**The hold timer is form-gated** — seconds accrue only while the pose stays inside tolerance. A sagging plank stops earning, which makes the form check the mechanic rather than a nag.

### Caps and curves
- Per-set cap, so one 500-rep set can't own the city
- Per-day soft cap with diminishing returns — protects leaderboards and users alike
- Streak multiplier applies to **XP only**, never to territory power, or territory becomes unwinnable for new users

### Downstream consumption
- **XP** = `RepScore × streakMultiplier`
- **Hex power** = `RepScore` earned inside that hex
- **Spot power** = `RepScore` earned at that spot
- **Personal records** = max reps, max hold, hardest tier unlocked — all camera-verified

---

## 5. Territory: two scales, one mechanic

Hexes and spots are the same game played at different resolutions. Same claim rules, same decay, same power. Only the geometry and the social texture differ.

| | **Hex** | **Spot** |
|---|---|---|
| Geometry | H3 res 8, ~0.74 km² | Point POI with a ~100 m radius |
| Feel | Anonymous, adversarial, city-scale | Named, social, repeated-game — you see the same faces |
| Claim by | Working out anywhere inside it | Working out while checked in at it |
| Shows as | Coloured cell on the map | Pin with a holder and a standing board |
| Examples | "the north end of the park" | Calisthenics rig at Riverside, PureGym Northgate |

**The rules, identical at both scales:**

| Rule | Decision | Why |
|---|---|---|
| Claim threshold | Minimum `RepScore` at the target to register a claim | Stops drive-by claims from a single rep |
| Capture | Your accumulated power exceeds the incumbent's | Simple, explainable in one sentence on stage |
| Decay | Power half-life **72 hours**, computed lazily on read | This *is* the retention mechanic. One decay system for both scales — don't build two |
| Location gate | GPS accuracy ≤ 50 m, or the session doesn't count toward territory | Indoor GPS is garbage; fail loudly rather than award the wrong hex |
| Spot proximity | Within ~100 m to check in | Tighter than hexes because spots are points |

**The two scales feed each other: every spot you hold adds a flat power bonus to its containing hex, for as long as you hold it.** That single rule turns two loops into one strategy — grind the open hex, or go contest the rig inside it and get both. It's also the answer to "why are there two systems?", which a judge will ask.

**Spot verification.** Spots come from a seeded list, and users can create missing ones. A user-created spot is `unverified` and earns nothing until **three distinct users** have completed sessions there — otherwise people spawn a spot in their bedroom and farm it.

Territory contributions accrue during a session and commit on submit. No continuous background location needed, which saves real build time and battery.

---

## 6. Functional requirements

### A — Identity & profile

| ID | Pri | Requirement |
|---|---|---|
| A1 | MUST | Sign in with Apple/Google, plus a guest path — a judge should never hit a signup wall |
| A2 | MUST | Profile: handle, avatar, level, lifetime RepScore, home spot, unlocked tiers |
| A3 | SHOULD | Device binding recorded at signup, carrying attestation state |
| A4 | COULD | Public profile view |

### B — Rep capture *(the hard part — protect this track)*

| ID | Pri | Requirement |
|---|---|---|
| B1 | MUST | Live camera preview with on-device pose inference; **target ≥15 fps, hard floor 10 fps** — degrade, never crash. Run ML Kit's `base` model in stream mode; `accurate` is a fallback only if the Day-2 gate fails on accuracy, never as a default |
| B2 | MUST | **No frame, image, or video ever leaves the device, ever.** ML Kit runs fully on-device; only derived numbers (angles, confidences, timestamps) are uploaded. Calisthenics-only is what lets this be absolute — there is no record claim that needs video proof |
| B3 | MUST | Per-movement rep state machine over joint angles using **two thresholds (hysteresis)**, so jitter at the turnaround can't double-count |
| B4 | MUST | Framing check before start — full body in frame — then a 3-2-1 countdown |
| B5 | MUST | **Audible rep count and form cues.** The phone is propped 2 m away on the floor; the screen is unreadable mid-set. Every live-feedback state — green, amber, red — carries an appropriate audio cue. Not a nice-to-have |
| B6 | MUST | On-screen overlay: rep count, skeleton, depth/ROM indicator, and the three-state live-feedback signal — **green** = tracking and form valid; **amber** = actionable correction (e.g. "go lower"); **red** = tracking lost, out of frame, or an invalid attempt completed. Every state is visibly signalled |
| B7 | MUST | Low-confidence reps still count but are flagged and reduce `formFactor` |
| B8 | SHOULD | Manual ± correction on the summary screen is a **local-only UI annotation** — displayed for the user, never transmitted, never alters server-scored results |
| B9 | MUST | Session summary: reps, RepScore, form grade, PR detection, any tier unlocked |
| B10 | MUST | **v1 movement set: squat, push-up, pull-up, jumping jack, plank** (§4). Pull-up reuses the push-up elbow-angle machinery, so it is the cheapest of the five to add once push-up works |
| B11 | MUST | **Per-movement camera placement guidance** before the set — an illustration plus one line ("phone on the floor, side view, 2 m back"). Placement differs per movement and users get it wrong by default. Cheap to build, and it's the difference between the counter working and not |
| B12 | MUST | **Hold capture** for `holdTime` movements: form-gated timer with a live in-form / out-of-form indicator |
| B13 | SHOULD | **Diary entry** for movements outside the catalogue — a future, non-competitive `DiaryEntry` (exercise name, sets, reps, optional weight/duration, notes). Private history and personal-PR context only: **zero competitive consequences** — no RepScore, no XP, no board, no territory, no mission progress. Self-reported activity is never Evidence |
| B14 | MUST | Movement is chosen explicitly before each set. Automatic recognition is **out of scope** — research problem, not a week-one feature |
| B15 | SHOULD | Tier unlock moment when a user qualifies for a harder variation (§4) |
| B16 | MUST | **Pull-up detection** on two independent signals: elbow angle (primary, same state machine as push-up) and shoulder-to-wrist vertical distance (confirmation, collapses toward zero at the top). The bar is never detected — the wrist landmarks *are* the bar |
| B17 | MUST | **Pull-up framing**: phone ≥3 m back, elevated toward chest height where possible, full body in frame. A steep upward angle from the ground compresses the vertical axis and degrades the estimate — B11's guidance card must say so explicitly |
| B18 | SHOULD | **Swing/kip penalty.** Kipping makes a pull-up materially easier, and horizontal hip displacement across a rep is directly measurable. Excess swing reduces `formFactor`, so strict reps score higher. This is a scoring-integrity requirement, not polish |

> **Live feedback is a strict three-state system.** **Green** — tracking and form are valid, the rep will count. **Amber** — the rep is recoverable: give one actionable correction ("go lower"), never vague encouragement. **Red** — tracking lost, athlete out of frame, or an invalid attempt completed. Every state has a visible signal *and* an audio cue (B5), because the screen is unreadable mid-set.

**Acceptance test for the whole track:** a 20-rep set at moderate tempo counts within **±1 rep**, across 3 different body types and 2 lighting conditions. If this fails on Day 2, trigger the fallback in §10.

> **Pull-ups are in v1, and they're easier to detect than they look.** You never detect the bar — the hands are on it, so the wrist landmarks give you its position for free. From there a pull-up is the same `shoulder-elbow-wrist` angle that drives push-ups (~180° at dead hang, ~50° at the top) through the same hysteresis state machine, with shoulder-to-wrist vertical distance as an independent confirmation. Enormous unambiguous range of motion, body vertical, nothing occluded — arguably a *cleaner* target than push-ups, where the far arm occludes from a side view. The real constraints are framing distance (B17) and swing (B18), and both are addressable.

### C — Workout session

| ID | Pri | Requirement |
|---|---|---|
| C1 | MUST | Start a session against a **server-issued session id**; capture location and spot context at start |
| C2 | MUST | Multiple sets per session, mixed movements |
| C3 | SHOULD | Rest timer between sets |
| C4 | MUST | Submit → server validates the rep stream, computes RepScore, writes the ledger, and returns **all consequences in one response**: XP, hex result, spot result, rank change, unlocks |
| C5 | SHOULD | Capture works offline; submissions queue and flush on reconnect |

> C4 is deliberately one round trip. The client should never make five calls to find out what just happened — that's what makes the post-workout screen feel good.

### D — Territory (hexes)

| ID | Pri | Requirement |
|---|---|---|
| D1 | MUST | Map screen with H3 res-8 hexes coloured by owner — yours, rival, unclaimed — with spot pins overlaid |
| D2 | MUST | Claim: earn ≥ threshold RepScore inside a hex → take it if your power exceeds the incumbent's |
| D3 | MUST | Power decays on a 72 h half-life, computed lazily on read — don't run a cron for this |
| D4 | MUST | Reject territory credit when GPS accuracy > 50 m, with a clear in-app explanation |
| D5 | MUST | Held spots contribute bonus power to their containing hex (§5) |
| D6 | SHOULD | Hex detail sheet: owner, power, your power, spots inside it, recent flips |
| D7 | SHOULD | Territory leaderboard — hexes held, total area |
| D8 | SHOULD | Notify the previous owner when a hex flips |
| D9 | COULD | Human-readable hex names from nearby POIs |

### E — Spots *(the gym rivalry loop)*

| ID | Pri | Requirement |
|---|---|---|
| E1 | MUST | Nearby spot discovery from a seeded list; users can create a missing spot |
| E2 | MUST | Check in by proximity (~100 m); set a home spot |
| E3 | MUST | Spot capture on the same power-and-decay mechanic as hexes (§5); current holder shown on the pin |
| E4 | MUST | Spot standing board with tabs: **current power**, **PR count**, **achievement points** |
| E5 | MUST | PR detection per movement — max reps in a set, max hold duration, hardest tier — with a celebratory moment |
| E6 | MUST | User-created spots stay `unverified` and score nothing until 3 distinct users have trained there |
| E7 | SHOULD | "You've lost the spot" / "you've been passed" notifications |
| E8 | COULD | Crew ownership; spot-vs-spot standings |

### F — Progression

| ID | Pri | Requirement |
|---|---|---|
| F1 | MUST | XP and levels on a published curve (e.g. `XP(n) = 100 × n^1.5`) with a level-up moment |
| F2 | MUST | **Variation tree unlocks** (§4): 50 verified reps at a tier unlocks the next |
| F3 | MUST | Daily streak counter |
| F4 | SHOULD | ~15 seeded achievements, evaluated server-side on ledger write |
| F5 | SHOULD | Badges and titles on profile and boards |
| F6 | COULD | Streak freeze token |

### G — Challenges

| ID | Pri | Requirement |
|---|---|---|
| G1 | SHOULD | Daily challenge, identical for all users that day, generated server-side *(Slice 1: one static seeded daily template — personalization is a later slice)* |
| G2 | COULD | Weekly challenge with a larger reward |
| G3 | SHOULD | Visible progress plus an explicit claim step — claiming feels better than auto-award |

### H — Notifications & feed

| ID | Pri | Requirement |
|---|---|---|
| H1 | SHOULD | Push: hex lost, spot lost, passed on a board, challenge expiring |
| H2 | COULD | Activity feed of nearby captures and PRs |

### I — Integrity & anti-cheat

Competitive fitness apps get cheated within hours, and the physics here is honest: the camera feed never leaves the device (B2), so the server can never *prove* a workout happened. It can only referee the evidence it's given — the same position Strava and Zwift occupy with far bigger budgets. The goal is not "uncheatable." It's a **cost ladder**: each attack costs meaningfully more than the one below, damage stays bounded while detection lags, and everything is reversible after the fact — which is what the append-only ledger (§3) is for.

**Calisthenics-only removes the bottom rung entirely.** With no weights, there is no declared number anywhere in the scoring path — nothing to inflate, no plausibility heuristics for typed values, no evidence clips, no disputes, no social policing. Every scored set is camera-derived, so **the only attack left is forging a pose stream**, and that is a single, well-defined problem you can actually attack.

**The client is a sensor; the server is the referee.** The client never submits a score — it submits evidence, and the server recomputes everything.

| Attack | Attacker cost | Defence | Where it lands |
|---|---|---|---|
| Replay a captured submission | Trivial — proxy + curl | One-shot sessions, wall-clock containment | **Structurally dead** |
| Forge a fresh payload by script | Low | Device attestation bound to the session | Needs an instrumented rooted device |
| Fake GPS | Low | `isMocked`, accuracy gate, teleport check | Bounded |
| Synthesise a plausible pose trace on a rooted phone | High — beat attestation *and* fake correlated human noise | Statistical validators, caps, retroactive voiding | Detectable, damage-bounded |

Judges will ask "what stops me from faking this?" — this table is the rehearsed answer, and it's a much stronger one than it was before the discipline narrowed.

#### Replay and session integrity

| ID | Pri | Requirement |
|---|---|---|
| I1 | MUST | Client uploads the **rep event stream** (timestamps, angle data, confidences), never a self-computed score. The server recomputes RepScore and is authoritative |
| I2 | MUST | **One-shot sessions.** `/session/start` issues a server-generated id; submitting consumes it. A second submission against the same id — verbatim or edited — is rejected. Unsubmitted sessions expire after 4 h |
| I3 | MUST | **Wall-clock containment.** The server records start and submit times itself; the claimed rep timeline must fit inside that observed window. A ten-minute workout submitted forty seconds after the session opened is rejected. No client clock is ever trusted |
| I4 | COULD | Certificate pinning, to make capturing traffic harder in the first place. Weakest layer — an attacker who owns the device strips it — hence lowest priority |

#### Provenance — is this the real app?

| ID | Pri | Requirement |
|---|---|---|
| I5 | SHOULD | **Device attestation on the demo platform** — Play Integrity (Android) / App Attest (iOS), verified in a Supabase Edge Function, token bound to the session id. Moves forgery from "curl" to "instrument a rooted device." Highest-leverage security work in the plan; scheduled Day 6 |

#### Content plausibility — is this a human?

| ID | Pri | Requirement |
|---|---|---|
| I6 | MUST | Cadence: reject inter-rep gaps < 0.4 s; flag near-zero tempo variance. Bots are metronomes; humans aren't |
| I7 | MUST | Location: reject implied travel > 40 km/h between session events; reject mock-location providers; accuracy gate per D4 |
| I8 | SHOULD | Upload the **downsampled angle time-series** (~5 fps), not only per-rep extrema. Faking twenty timestamps is easy; synthesising a full trace with correlated noise, plausible biomechanics and fatigue drift is not. Validators run async after submission, so this costs the UX nothing |
| I9 | SHOULD | Fatigue drift: humans slow across a set. Twenty reps at identical tempo draws a flag |
| I10 | MUST | **Tier gating doubles as anti-cheat**: a user cannot score a movement they haven't unlocked (§4), so nobody arrives claiming pistol squats with no history behind them |

#### Response — always reversible

| ID | Pri | Requirement |
|---|---|---|
| I11 | MUST | Rate limits: max sessions/day, max RepScore/day per account |
| I12 | MUST | Flagged sessions are voidable; every board recomputes from the ledger |
| I13 | SHOULD | **Shadow-flag, don't hard-ban.** During a hackathon, a false positive that locks out a judge is far worse than a cheater |

**Named for v2, deliberately not this week:** a liveness challenge — the server picks a random gesture for the countdown ("raise your left arm") and the trace must contain it at the right moment, which defeats pre-fabricated streams outright; wearable heart-rate corroboration. The remaining honest gap: a rooted device plus a statistically perfect synthetic trace beats all of this. Every fitness platform lives with that attacker. Caps bound the daily winnings, decay makes stolen territory expensive to keep, and the ledger makes cleanup retroactive rather than impossible.

### J — Demo & operations *(the section teams skip and then lose on)*

| ID | Pri | Requirement |
|---|---|---|
| J1 | MUST | Seed script: ~30 plausible users, populated hexes and spots around the demo venue, a competitive standing board |
| J2 | MUST | **Mock-location mode** — local staging support for the on-stage demo. The server permits only a fixed server-authorized demo location and seeded Spot for allowlisted demo accounts (J7); mocked GPS from production accounts is rejected |
| J3 | MUST | One-command reset to a clean demo state for repeat run-throughs |
| J4 | MUST | Written demo script plus a rehearsed happy path, verified on the exact phone you'll present with |
| J6 | MUST | **Confirm a pull-up bar for demo day** (venue rig, doorway bar, or a pre-recorded fallback set filmed on the real app). Resolve by Day 5 — see §10 |
| J7 | MUST | **Demo-board routing is server-side** — derived from an authenticated, allowlisted demo account (server-side config). Never from Evidence fields, build flags, or client-side toggles. A client cannot opt itself into demo mode. A demo account is permitted only the fixed server-authorized demo location and seeded Spot; mocked GPS is rejected for production accounts. Demo-board data never appears in production competitive reads; it may appear only in the isolated demo-board experience |
| J5 | SHOULD | Crash and error reporting visible to the team on demo day |

---

## 7. Non-functional requirements

| ID | Area | Requirement |
|---|---|---|
| N1 | Performance | Pose inference ≥15 fps on a mid-range device; graceful degradation to 10 fps |
| N2 | Performance | Map renders 500+ hexes plus spot pins without jank |
| N3 | Performance | Score submission round trip < 800 ms p95 |
| N4 | Performance | Cold start < 3 s |
| N5 | Battery/thermal | A 10-minute camera session must not thermally throttle the demo device |
| N6 | Privacy | **Camera frames are never transmitted or persisted — no exceptions.** Say it in the app *and* in the pitch; it's a differentiator, and calisthenics-only is what makes it unconditional |
| N7 | Privacy | Location stored as H3 index + coarse timestamp, never a raw GPS trace |
| N8 | Privacy | Permission priming screens explaining *why* before the OS prompt (camera, location, notifications) |
| N9 | Accessibility | Audio-first workout mode (B5); large-type score readout; colour is never the only signal of ownership |
| N10 | Data | Account delete and export path defined, even if manual this week |
| N11 | Reliability | A failed submission never loses a workout — it queues locally |

---

## 8. The stack

**Decided: Flutter.** The deciding factor is Track A — ML Kit's pose API has a maintained Flutter plugin, which is the shortest path to a working rep counter, and Track A is the critical path.

| Layer | Choice | Notes |
|---|---|---|
| Client | **Flutter** | Single codebase; `CustomPainter` for the hex overlay and capture HUD |
| Pose | **`google_mlkit_pose_detection`** | On-device BlazePose, 33 landmarks, free. `base` (fast) and `accurate` models — start on `base` |
| Camera | **`camera`**, via `startImageStream` | The plumbing risk lives here, not in ML Kit — see below |
| Backend | **Supabase** + `supabase_flutter` | Postgres + PostGIS, auth, realtime boards, row-level security. First-party Flutter SDK |
| Map | **`flutter_map`** | Preferred over `google_maps_flutter`, which is a platform view and degrades at the polygon count N2 requires |
| Location | **`geolocator`** | Exposes accuracy (D4) and `isMocked` on Android, which serves I7 directly |
| Audio cues | **`flutter_tts`** | For B5 |
| State | **Decide Day 1 — Riverpod suggested** | With three devs, an unstated state convention diverges by Day 3 |

### The one genuinely Flutter-specific risk

ML Kit itself is easy. **Getting a frame out of the `camera` stream and into a correctly-formed `InputImage` is not.** Rotation handling, YUV420 on Android vs BGRA on iOS, and plane layout are the well-documented sharp edges. Day 1 on Track A is reserved for exactly this and nothing else.

Two platform-config items block everyone from running on device until they're done — A owns both in the first two hours:

- Android `minSdkVersion` bump, plus camera and location permissions in the manifest
- iOS deployment-target bump and camera/location usage strings in `Info.plist`. ML Kit pods add noticeably to iOS build time and binary size

### Still open

1. **H3 in Dart is thin.** The Dart bindings are community-maintained and less proven than `h3-js`. **Compute cell indices and boundary polygons server-side** (Postgres has an H3 extension) and ship plain coordinates — then the app needs no H3 library at all, it just draws polygons. Worth doing regardless of framework.
2. **Demo device.** Pick one phone, one OS, today. Test on it daily. Do not split effort across platforms.
3. **No OTA safety net.** Unlike Expo's EAS Update, a last-minute fix means a full rebuild and reinstall. That's the real cost of the Flutter choice — it's why the Day 6 noon freeze is non-negotiable and Day 7 is rehearsal only.

---

## 9. Seven-day plan — three people, three tracks

### Ownership

Each track has exactly one owner, accountable for that track's gate rather than just its tickets.

| Track | Owner | Owns |
|---|---|---|
| **A — Capture** | Dev 1 | Platform config, camera pipeline, pose inference, rep state machines, capture UI, audio cues. Calls the Day-2 go/no-go |
| **B — Core** | Dev 2 | Schema, auth, scoring service, ledger, territory resolution at both scales, integrity, every API, seed script |
| **C — Surface** | Dev 3 | App shell, navigation, design system, map, boards, profile, progression UI, notifications, demo mode, rehearsal |

### The two dependencies that decide whether this works

With three people the risk stops being "can we build it" and becomes "are two people blocked waiting on the third." There are exactly two such choke points, and both close on Day 1:

1. **C is blocked by B.** Every screen C builds needs an endpoint B hasn't written. → **B publishes the API contract on Day 1** — shared types plus stubbed endpoints returning realistic fake data — *before* writing real logic. C builds every screen against stubs and swaps to live data on Day 3.
2. **Everyone is blocked by platform config.** Nobody can run on a real device until `minSdkVersion`, the iOS deployment target, and permission entries are in place. → A does this in the **first two hours**, before touching a line of pose code.

### Day by day

**Day 1 — Spikes and contracts**
- **A** — Platform config pushed in the first two hours. Then the entire rest of the day on one thing: `camera` stream → correctly-formed `InputImage` → pose landmarks rendering on the demo phone. Nothing else.
- **B** — Schema + auth. **Publish the API contract with stubbed responses by end of day.**
- **C** — App shell, navigation, design tokens, map rendering H3 cells and spot pins with fake ownership.
- **Gate:** keypoints visible on a real phone, *and* C can call every endpoint against stubs.

**Day 2 — Prove the risky thing**
- **A** — Squat state machine to ±1 accuracy. Test on all three of you, two lighting conditions.
- **B** — Scoring service, ledger writes, session submission — with one-shot session ids and wall-clock containment (I2–I3) in the first draft. Replay protection is API shape, not a later security sprint.
- **C** — Boards, profile, hex and spot detail, session summary — all against stubs.
- **Gate:** **±1 rep on a 20-rep set.** The go/no-go — see §10 if it fails.

**Day 3 — Integration day** *(half of today is integration, not features — plan for it)*
- **A** — In this order: **push-up → pull-up** (reuses push-up's elbow-angle code, so build them back to back while it's in your head) → plank (hold type, no state machine at all) → jumping jack. **If the day runs long, jumping jack slips — pull-up does not.** It's the lowest-difficulty movement in the catalogue and the least missed.
- **B** — Claim resolution and decay for **both** hexes and spots on the shared mechanic; the single-round-trip submission response (C4).
- **C** — Rip out stubs, wire live APIs, map shows real ownership at both scales.
- **Gate:** a real workout, by a real person, flips a real hex. End to end, no mocks.

**Day 4 — Second scale**
- **A** — Form scoring, session summary, PR moment, tier-unlock moment. *A's CV work is largely done after today — from here A absorbs work off whichever track is behind.*
- **B** — Spots: discovery, check-in, capture, standing boards, PR detection, the spot→hex bonus, 3-user verification.
- **C** — Spot screens, progression UI (XP, level, streak, variation tree).
- **Gate:** both scales reachable end to end. Sanity-check the hold-to-rep conversion (§4) against a real set.

**Day 5 — Depth**
- **A** — Audio rep cues (B5), capture UX polish, **full 10-minute thermal/battery test on the demo phone**.
- **B** — XP curve, tier unlocks, achievements, challenges, notification backend.
- **C** — Level-up and unlock moments, push notifications, empty states, error states.
- **Gate:** feature complete.

**Day 6 — Harden. Freeze at noon.**
- **A** — Capture bug fixes; accuracy testing under actual venue lighting.
- **B** — Device attestation (I5), plausibility validators (I8–I10), rate limits, seed script, one-command reset.
- **C** — Demo mode toggle, seeded venue data on the map, visual polish.
- **Gate:** **feature freeze at 12:00.** Afternoon is bugs only, no exceptions.

**Day 7 — Demo, zero planned coding**
- All three rehearse together. Three clean run-throughs minimum.
- Roles: **A holds the phone and performs**, **B watches server logs**, **C drives the map and boards on the second screen**.
- The buffer exists because it always gets used. Protect it.

### Standing rules

- **15 minutes standup, 15 minutes integration check.** Start and end of day. That's the entire process overhead for a team of three — anything more is theatre.
- **A is the critical path.** Whoever finishes their day's work first pulls the next item off Track A's list.
- **One demo phone.** It lives with A through Day 6, then with whoever presents. Test on it daily, not on a simulator.
- **After Day 6 noon, no solo merges to main.** Two sets of eyes on every change.
- **If you're behind on Day 4**, cut in this order: challenges → achievements → higher variation tiers → territory decay → notifications. **Never cut a scale** — a demo with hexes working and spots broken is worse than one polished scale.

---

## 10. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| **Pose counting isn't accurate enough** | Kills the product's credibility | Hard go/no-go end of Day 2. Fallback: the camera is demoted to a "form check" showpiece and the demo ships with whichever movements pass the gate — Slice 1 (squat) first. **There is no manual scoring path** — self-reported activity is diary-only and never scores. **B and C are unaffected**: the Evidence → server → ledger loop is not coupled to any particular movement, so only the capture UI changes. Decide at the gate; don't drift |
| **Camera stream → `InputImage` plumbing** | Blocks all of Track A | The known Flutter sharp edge: rotation, YUV420 vs BGRA, plane layout. All of Day 1 is reserved for it. Not solved by end of Day 1 → escalate that evening; do not let it bleed into Day 2 |
| **Platform config churn** (minSdk, iOS target, ML Kit pods) | Blocks everyone from running on device | A pushes it in the first two hours of Day 1 |
| **Dart H3 bindings are immature** | A late, avoidable surprise in the map layer | Compute cells and boundaries server-side; the client only ever draws polygons |
| **Two scales, one week** | Both end up half-built | They share one claim mechanic by design (§5). Build it once on Day 3, apply it to spots on Day 4 |
| **Forged or replayed submissions** | Poisoned boards, stolen territory | Replay dies structurally on Day 2 (I2–I3); attestation Day 6 raises forgery to instrumented-device cost; daily caps bound the blast radius; the ledger makes cleanup retroactive |
| **Two devs idle waiting on the third** | Silently loses a day or more | Both choke points are named in §9 and close on Day 1 |
| **Three tracks, no integration until late** | Everything works separately, nothing works together | Day 3 is an explicit integration day; the end-of-day integration check runs from Day 1 |
| **No pull-up bar at the demo venue** | The signature movement can't be shown live | Now a logistics problem, not a product one. Carry a doorway bar, scout the venue for a rig, or open on squats and cut to a pre-recorded pull-up set filmed on the real app. Decide by Day 5, not on the morning |
| **Kipping inflates pull-up scores** | Trivially gameable signature movement | B18 measures hip displacement and penalises `formFactor`. Tune the threshold against a real kipping set on Day 5 — too tight and honest reps get docked |
| **No OTA updates** | A Day-7 bug needs a full rebuild and reinstall | Hard freeze Day 6 noon, three rehearsals, and keep a known-good signed build installed on the demo phone |
| **Thermal throttling during the demo** | Frame rate collapses on stage | Test a full 10-minute session on the demo phone by Day 5; keep it plugged in and cool |

---

## 11. Done means this

The demo is the acceptance test. One continuous take, ~90 seconds, no cuts and no mocked screens:

1. Open the app at the venue → the map shows contested hexes and spot pins around you
2. Start a session at the spot you're standing at → prop the phone → do 10 squats → counter and voice track every rep
   - **If a bar is available, open on pull-ups instead.** It's the signature movement and far more impressive on stage. Keep squats as the fallback — they need no equipment and a judge can try them unprompted, which is its own kind of proof
3. Finish → summary shows reps, RepScore, form grade, a new PR, and progress toward the next variation tier
4. The map animates: your hex flips, and the spot pin flips to you
5. The spot's standing board moves you to the top
6. Level-up

If every step works on the demo phone, on the venue's network, three times in a row — you're done.
