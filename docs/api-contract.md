# RepRush — API Contract

**Owner: B (Dev 2).** Companion to [requirements.md](requirements.md) (*what*) and [roles.md](roles.md) (*who*).

| Section | Status | Freeze |
|---|---|---|
| [§evidence](#evidence) | **Draft — B to own and tune** | End of Day 1 |
| [§endpoints](#endpoints) | Not started (B-3) | End of Day 1 |
| [§state](#state) | Not started (C-3) | Day 1 |

> Every threshold number in §evidence is a **Day-2 starting guess**, not a decision. They exist so A has something to run on Day 2 morning; A tunes them against the fixture corpus (A-15) and reports the tuned values back here. What is frozen is the **shape**, not the constants.

---

## §evidence

### What Evidence is

Evidence is **derived measurement over a landmark stream, at three granularities**. It is the only thing that crosses a track boundary in the capture path ([roles.md §4 Seam 1](roles.md#4-the-seams--where-two-people-meet)).

Per frame, ML Kit gives up to 33 landmarks, each with `x`, `y` in image pixels and a `likelihood`. Everything below is derived from that and nothing else.

| Level | What it is | Emitted |
|---|---|---|
| **Set** | Movement, timing, capture quality, calibration | Once per set |
| **Rep** | One record per detected rep — the numbers that made it a rep | On each rep transition |
| **Trace** | ~5 Hz downsample of the primary signal + confidence | Continuously |

**A caveat on `likelihood`.** ML Kit's per-landmark value is `inFrameLikelihood` — strictly "is this landmark inside the frame," not "how confident am I in its position." It correlates with occlusion and framing, so it is a usable confidence proxy, but do not describe it as a position confidence in the pitch.

### The primary signal

Each movement config names **one primary scalar**, which is either a joint angle or a normalised distance ratio. Reps are detected on that one signal; everything else is confirmation or grading.

Signals come in two directions:

- `decreasing` — the value falls as the athlete moves into the hard position (squat, push-up, pull-up)
- `increasing` — the value rises (jumping jack)

States are **`REST`** and **`PEAK`**, not up/down — a pull-up starts extended and flexes upward, so up/down is ambiguous across movements.

### The rep state machine

```
REST  --( primary crosses enterPeak )-->  PEAK      begin tracking the extreme
PEAK  --( primary crosses enterRest )-->  REST      EMIT A REP
```

A rep is emitted when the athlete **returns to rest having passed through peak**. That is uniform across every movement: stand→bottom→stand, top→bottom→top, hang→chin-over→hang.

The gap between `enterPeak` and `enterRest` is the **hysteresis band**. Jitter inside the band cannot flip the state, which is what stops double-counting at the turnaround (B3).

**Smoothing is mandatory, upstream of the state machine.** Raw ML Kit angles jitter several degrees frame to frame and hysteresis alone will not absorb it. An EMA or one-euro filter on the primary signal is ~5 lines and is the difference between the counter working and not.

On emit, the accumulated rep record is already complete: start/end timestamps, the rest-side extreme before departure (`restExtreme`), the peak-side extreme reached (`peakExtreme`), mean and min confidence of the landmarks forming the signal, and the concentric/eccentric split.

### Movement configs — Day-2 starting values

| Movement | Primary signal | Direction | Rest | `enterPeak` | `enterRest` | `romTarget` | Confirming signal |
|---|---|---|---|---|---|---|---|
| `squat` | knee angle · hip–knee–ankle | decreasing | ~175° | 110° | 150° | 80° | hip height / torso length |
| `push_up` | elbow angle · shoulder–elbow–wrist | decreasing | ~165° | 110° | 145° | 85° | torso straight, 160–185° |
| `pull_up` | elbow angle · shoulder–elbow–wrist | decreasing | ~175° | 90° | 150° | 55° | `shoulderWristDyNorm` < 0.25 (B16) |
| `jumping_jack` | `ankleSepNorm` · ankle sep / shoulder width | increasing | ~0.35 | 1.20 | 0.60 | 1.60 | wrists above shoulder line |
| `plank` | trunk angle · shoulder–hip–ankle | hold | ~178° | — | — | — | in-form band 160–185° |

**Use the higher-confidence side per frame**, not a hardcoded left or right. On a side-view push-up the far arm is occluded; ML Kit still emits landmarks for it at lower likelihood, and picking the wrong limb is a silent accuracy killer.

`pull_up`'s `enterPeak` is the value most likely to need tightening — 90° is deliberately lenient so honest reps are not rejected on Day 2. Tighten it against real sets, not in the abstract.

### Versioned calibration

Thresholds are **rest-relative offsets**, not absolute angles:

```
threshold = calibration.restSignal + offset
```

`calibration.restSignal` is captured during the 3-2-1 countdown — the athlete's own rest pose, not a constant. The active offset set ships as a named **`movementConfigVersion`**:

- `POST /session/start` returns the current version and binds it to the session.
- The client uses that version for every set in the session and echoes it back in `POST /session/submit`.
- The server rejects a submission whose version does not match the session's recorded version. Clients cannot select an older configuration version — the server always issues the current one.

The offsets below are **Day-2 starting values**, derived from the absolute threshold table above. A tunes them against the fixture corpus (A-15); a tuned set is a new version, never a silent edit.

| Movement | `enterPeak` offset | `enterRest` offset | `romTarget` offset |
|---|---|---|---|
| `squat` | −65° | −25° | −95° |
| `push_up` | −55° | −20° | −80° |
| `pull_up` | −85° | −25° | −120° |
| `jumping_jack` | +0.85 | +0.25 | +1.25 |
| `plank` | absolute in-form band 160–185° (hold mechanic — no offsets) |||

### ROM — enforced in two places

This is the part that reads as arbitrary if the two roles are conflated. They are separate mechanisms:

**The threshold is the gate.** A shallow squat never crosses `enterPeak`, so it never changes state, so it is never a rep. Not counted-then-penalised — it does not exist. ROM enforcement for *counting* is free; it falls out of where the threshold sits.

**Depth beyond the threshold is the grade.**

```
romScore = clamp( (peakExtreme - enterPeak) / (romTarget - enterPeak), 0, 1 )
```

The signs cancel, so one formula covers both directions.

| Example | Computation | Result |
|---|---|---|
| Squat, `peakExtreme` 95° | `(95−110)/(80−110)` | 0.50 |
| Squat, `peakExtreme` 78° | `(78−110)/(80−110)` = 1.07 | 1.00 (capped) |
| Pull-up, `peakExtreme` 52.8° | `(52.8−90)/(55−90)` = 1.06 | 1.00 |
| Jumping jack, `peakExtreme` 1.45 | `(1.45−1.20)/(1.60−1.20)` | 0.63 |

### formFactor

```
confScore  = clamp( confMean / 0.70, 0, 1 )
formFactor = 0.60 + 0.40 × ( 0.60 × romScore + 0.40 × confScore )
```

Lands in **[0.6, 1.0]**, matching [requirements.md §4](requirements.md). Penalties (kip/swing, B18) apply multiplicatively on top.

`confScore` is floored rather than linear on purpose: at `confMean ≥ 0.70` it contributes 1.0 and never bites. Good lighting is never rewarded, but poor lighting degrades gracefully instead of scaling from zero. B7 requires low-confidence reps to count-but-be-penalised; this is the mildest reading of that which still satisfies it.

Set-level `formFactor` is the mean across reps. **The server recomputes all of this** — the client sends `peakExtreme`/`restExtreme` and `confMean`, never a `formFactor` and never a score (I1).

### Holds

A different mechanic — **no state machine**. Per frame, evaluate the in-form predicate (plank: trunk angle within 160–185°) and accumulate time while true. Output is `holdSegments`, not reps.

**Open decision for B:** is 3 × 20 s worth the same as 1 × 60 s? If segments simply sum, micro-breaks are free and the movement is gameable. Suggested default — only segments ≥ 5 s count, and total is discounted by segment count. Settle this when the hold-to-rep conversion is sanity-checked on Day 4.

### Calibration — captured during the 3-2-1 countdown

The largest threat to fixed absolute thresholds is that **a 2D joint angle depends on viewing angle**. A knee measured 45° off-axis does not read the same degrees as one measured side-on.

Three mitigations, all of which should ship: placement cards force a consistent view (A-12), the framing check can reject a bad one (A-9), and — the cheap strong one — **capture a calibration frame during the countdown**. Record the athlete's rest-pose angles and body scale, then express thresholds relative to their own start pose (see *Versioned calibration* above). That absorbs body proportions and camera-angle drift in a single move.

### The normalisation rule

**Any measurement in pixels is meaningless across distances** — the same kip is half the pixels from twice as far. Every distance-derived field carries a `Norm` suffix and is divided by a calibration scale reference:

| Field | Divided by |
|---|---|
| `hipDriftNorm` (B18 kip) | shoulder width |
| `shoulderWristDyNorm` (B16) | torso length |
| `ankleSepNorm` (jumping jack) | shoulder width |

No raw `...Px` field may appear in a rep record. Pixels live in `calibration` only.

### The shape

```jsonc
{
  "sessionId": "<server-issued, one-shot>",     // I2
  "movementConfigVersion": "<server-issued at /session/start>",
  "clientVersion": "1.0.3",
  "attestationToken": "<Day 6>",                 // I5
  "location": { "lat": 0, "lng": 0, "accuracyM": 0, "isMocked": false },
  "spotId": null,

  "sets": [{
    "movementId": "pull_up",
    "measurementType": "repBodyweight",          // | "holdTime"
    "startedAtMs": 0,
    "endedAtMs": 48200,

    "capture": {                    // how good was the observation
      "fpsMean": 14.8,
      "framesTotal": 713,
      "framesDropped": 12,
      "modelVariant": "base"
    },

    "calibration": {                // from the 3-2-1 countdown
      "torsoLengthPx": 210,         // scale reference for every *Norm field
      "shoulderWidthPx": 118,
      "restSignal": 176.0           // their actual dead hang, not a constant
    },

    "reps": [{
      "i": 0,
      "tStartMs": 1200,
      "tEndMs": 3050,
      "restExtreme": 174.2,         // extension before departure
      "peakExtreme": 52.8,          // deepest point — drives romScore
      "confMean": 0.88,
      "confMin": 0.71,
      "concentricMs": 900,
      "eccentricMs": 950,
      "hipDriftNorm": 0.08,         // B18 — / shoulder width, never pixels
      "shoulderWristDyNorm": 0.12   // B16 second signal — / torso length
    }],

    "holdSegments": [],             // B12 — [{ tStartMs, tEndMs, meanSignal, confMean }]

    "trace": {                      // I8 — parallel arrays, ~10x smaller than objects
      "hz": 5,
      "t0Ms": 0,
      "primary": [174, 170, 150, 121, 88, 61, 55, 72, 110, 168],
      "confMean": [0.90, 0.89, 0.85, 0.83, 0.80, 0.79, 0.81, 0.86, 0.88, 0.90]
    },

    "clientRepCount": 10            // reconciliation only — never trusted (see Attempts vs reps)
  }]
}
```

**The client never sends a score.** If a PR adds a `score`, `xp`, or `formFactor` field here, reject it (I1).

**Evidence is camera-derived only.** There is no provenance field and no self-report path into Evidence — Evidence exists only when the camera pipeline produced it. Self-reported activity is a separate, future, non-competitive concept (see *DiaryEntry* below) and never becomes Evidence.

### Attempts vs reps

An *attempt* is a partial movement that never crossed `enterPeak` — a shallow squat, an aborted pull-up. Invalid attempts are **local-only**: they drive the red feedback state in the capture UI and are **never serialized, never included in Evidence**. Only completed reps (`reps[]`) cross the track boundary.

`clientRepCount` exists for reconciliation only — the server compares it against `reps.length` to spot dropped events. It is never trusted as a count. The authoritative client-derived count is `reps[]` itself, subject to server validation; everything above it (score, XP, territory) is computed server-side.

**DiaryEntry (future, v2 — not Evidence).** Users may one day log workouts the camera can't verify: `exerciseName`, `sets`, `reps`, optional `weightKg`, optional `durationSeconds`, `notes`, `performedAt`. Diary entries are **private history and personal-PR context only**. They never grant score, XP, territory power, mission progress, unlocks, or leaderboard standing (B13).

**Demo-board routing is server-side context**, not an Evidence field. The server decides whether a session belongs to the isolated demo board from the authenticated account and server-side allowlist configuration (J7). A client cannot opt itself into demo mode — no Evidence field, build flag, header, or client-side toggle may influence this decision. Demo-board data never appears in production competitive reads; it may appear only in the isolated demo-board experience.

**`buildChannel`** (e.g. `"production"`, `"staging"`) may be included in Evidence for **telemetry only**. It must never authorize demo mode, bypass integrity checks, or influence scoring. If no telemetry consumer exists, omit it entirely.

### What the server can actually verify

Three levels, and the ceiling is worth stating plainly to the team so nobody oversells it on stage.

**1 · Recompute.** The server recomputes `romScore`, `formFactor` and `RepScore` from the uploaded numbers. This satisfies I1 — but it is recomputation from client-supplied *measurements*.

**2 · Cross-check the summary against the trace.** This is the check that earns its keep. Per rep window `[tStartMs, tEndMs]`, take the extreme of `trace.primary` over that window:

- `peakExtreme` must be **at least as extreme** as the trace extreme — 5 Hz sampling can only *miss* the true peak, never overshoot it
- …and within tolerance of it (**15°**, or 0.15 for ratio signals). A rep claiming a 52° `peakExtreme` when the trace bottoms out at 110° is a contradiction
- Threshold crossings counted directly in `trace.primary` must be within ±1 of `reps.length`

A forger now has to fake **two representations coherently**, which is a materially different problem from faking twenty numbers.

**3 · What is not verifiable.** The server cannot confirm a human was in front of the camera. Nothing can — see [requirements.md §6-I](requirements.md). Attestation raises the cost, caps bound the daily winnings, decay makes stolen territory expensive to hold, and the append-only ledger makes cleanup retroactive. That is the whole defence and it is the same one Strava and Zwift run.

So: **form is not verified, it is gated and graded.** Measurement correctness is checkable only for internal consistency.

### Raw landmarks — explicitly out of this week's contract

Uploading the raw 33-landmark stream was considered and rejected for this week's contract — roughly 150 KB of JSON per set before compression, no OTA safety net to fix it if it hurts the venue network, and Day 6 freezes at noon. The **derived ~5 Hz `trace`** (primary signal + confidence) is what ships and what the validators cross-check (I8). Revisit post-demo if B needs a signal A never emitted.

---

## §endpoints

*Stubbed responses with realistic fake data due end of Day 1 (B-3). C builds every screen against these stubs through Day 2 and swaps to live data on Day 3.*

**Session lifecycle.** Sessions are **one-shot** (I2) and wall-clock bounded (I3). Session IDs are server-issued UUIDs, created by `POST /session/start` — no locally generated session ID is ever accepted. `POST /session/start` also returns the current `movementConfigVersion` and binds it to the session. **Session context is deterministic:** if the Evidence `location`/`spotId` does not match the server-recorded session-start context, the submission is rejected with `SESSION_CONTEXT_MISMATCH`. Territory resolution always uses the server-recorded start context.

### Common rules

- **Auth:** every endpoint requires a Supabase auth bearer token; the guest path (A1) issues one too.
- **Errors:** `4xx` responses carry a stable machine-readable `code` plus a human `message`. Unknown codes are a contract bug — report them, don't guess at handling.
- **Stubs:** return populated, realistic data — contested hexes, non-empty boards, a plausible unlock — never empty arrays.
- **Demo sandbox (J7):** mocked GPS is rejected for production accounts. A server-authorized demo account is permitted a **fixed demo location** — substituted server-side — and its sessions/check-ins count only against the **isolated demo board**. No client request field can request, extend, or force demo context.

### POST /session/start

Open a one-shot session and fix its context.

- **Request:** `{ "location": { lat, lng, accuracyM, isMocked }, "spotId": null }`
- **Response:** `{ "sessionId", "serverStartMs", "movementConfigVersion", "hexH3", "spotId", "expiresAtMs" }` — the session-start context that submit must match and that territory resolves from.
- **Validation:** `accuracyM > 50` → `400 GPS_TOO_INACCURATE` (D4); implied teleport from the last session → `400 IMPLAUSIBLE_TRAVEL` (I7).
- **Errors:** `401 UNAUTHENTICATED`; `400 MOCKED_LOCATION_REJECTED` for production accounts with `isMocked: true` (I7). Demo accounts: the fixed server-authorized demo location is substituted server-side.
- **Stub:** fixed UUID, `movementConfigVersion: "2026-08-30.1"`, a seeded venue hex, 4 h expiry.

### POST /session/submit

Consume the session; return **all consequences in one response** (C4).

- **Request:** the full Evidence object (§evidence shape).
- **Response:** `{ "xp", "level", "levelUps", "hexResult", "spotResult", "rankChange", "unlocks", "prs", "achievements", "voided": false }`.
- **Validation:**
  - Session exists, belongs to the account, is unused, and unexpired (I2) → `SESSION_ALREADY_USED` / `SESSION_EXPIRED`
  - Claimed rep timeline fits the server-observed wall-clock window (I3) → `TIMELINE_OUT_OF_WINDOW`
  - `movementConfigVersion` matches the session's recorded version — no downgrades → `CONFIG_VERSION_MISMATCH`
  - Session context — the Evidence `location`/`spotId` must match the server-recorded session-start location and spot context, or the submission is rejected with `SESSION_CONTEXT_MISMATCH`. Territory resolution always uses the server-recorded start context (GPS validity D4/I7; spot context C1/E2)
  - Trace/summary cross-check (B-25) — disagreement **shadow-flags** the session (I13); it never hard-rejects at the gate
  - Cadence and tempo plausibility (I6, I9); per-set and per-day caps (I11)
- **Stub:** scores the B-24 fixture, flips the seeded hex, returns one PR and one rank change.

### GET /territory/hexes?bbox=

- **Request:** `bbox=swLat,swLng,neLat,neLng`.
- **Response:** `[{ "h3", "polygon": [[lat, lng], ...], "ownerHandle", "ownerColor", "power", "yours" }]` — plain coordinates; H3 is computed server-side (§8 open-1).
- **Validation:** oversize bbox → `400 BBOX_TOO_LARGE`.
- **Stub:** ~40 seeded hexes around the venue, mixed ownership.

### GET /territory/hex/:h3

- **Response:** `{ "h3", "ownerHandle", "power", "yourPower", "spots", "recentFlips" }`.
- **Errors:** `404 UNKNOWN_HEX`.
- **Stub:** one contested hex with two flips and one spot inside.

### GET /territory/leaderboard

- **Response:** `[{ "rank", "handle", "hexesHeld", "areaKm2" }]`.
- **Stub:** a seeded 10-row board with the demo user climbing it.

### GET /spots/nearby?lat=&lng=&radiusM=

- **Response:** `[{ "id", "name", "type", "lat", "lng", "verified", "holderHandle", "distanceM" }]`.
- **Validation:** `radiusM > 2000` → `400 RADIUS_TOO_LARGE`.
- **Stub:** the seeded venue spots, one held, one open.

### POST /spots

Create a user spot — always `unverified` (E6).

- **Request:** `{ "name", "type", "lat", "lng" }`.
- **Response:** `{ "id", "verified": false }`.
- **Validation:** bad type → `422 UNKNOWN_SPOT_TYPE`; duplicate within 50 m → `409 SPOT_TOO_CLOSE`.
- **Stub:** returns a fresh id.

### POST /spots/:id/checkin

- **Request:** `{ "location": { lat, lng, accuracyM, isMocked } }`.
- **Response:** `{ "checkedIn": true, "spotId" }`.
- **Validation:** >100 m from the spot → `400 OUT_OF_PROXIMITY` (E2); `accuracyM > 50` → `400 GPS_TOO_INACCURATE`.
- **Errors:** `400 MOCKED_LOCATION_REJECTED` for production accounts (I7). Demo accounts may check in only at the fixed seeded demo spot, substituted server-side (J7).
- **Stub:** accepts at the seeded venue spot.

### GET /spots/:id/board?tab=

- **Request:** `tab` ∈ `power` | `pr` | `achievements` (E4).
- **Response:** `[{ "rank", "handle", "value" }]`.
- **Validation:** unknown tab → `422 UNKNOWN_TAB`.
- **Stub:** three populated boards, demo user mid-table.

### GET /me

- **Response:** `{ "handle", "avatarUrl", "level", "xp", "lifetimeRepScore", "homeSpotId", "unlockedTiers" }`.
- **Stub:** level 3, one unlock pending.

### GET /movements

- **Response:** `[{ "id", "family", "tier", "difficulty", "measurementType", "unlocked", "repsTowardNextTier" }]` — the catalogue plus per-user state (A configs, C-7 tree).
- **Stub:** T1/T2 unlocked, pull-up at 32/50 toward wide-grip.

### GET /challenges/daily · POST /challenges/daily/claim

- **GET response:** `{ "templateId", "description", "target", "progress", "claimed" }`. Progress counts **verified, server-scored results only**.
- **POST response:** `{ "claimed": true, "xpAwarded" }`.
- **Errors:** `409 NOT_COMPLETE`, `409 ALREADY_CLAIMED`.
- **Missions rule:** Slice 1 ships one static seeded daily challenge, identical for everyone. Adaptive Missions (`ChallengeTemplate` / `MissionAssignment` / `MissionProgress`) are a later slice. **Missions may award capped XP only.** Territory power accrues only from verified RepScore earned in a session; missions never add territory power directly.
- **Stub:** "50 squat reps today", 20/50.

### POST /devices/attest

Day 6 (I5).

- **Request:** `{ "platform", "attestationPayload" }`.
- **Response:** `{ "bound": true }`.
- **Errors:** `422 ATTESTATION_INVALID`.
- **Stub:** returns `bound: false` until B-19 lands.

---

## §state

*C-3 — state-management convention, decided Day 1 with all three in the room. The stack is **Riverpod**.*

1. **Feature-scoped providers.** One provider family per feature (`capture`, `session`, `territory`, `spots`, `progression`). No god-object app state; no provider reaching across features except through a repository.
2. **Repositories wrap all API access.** Every endpoint lives behind a typed repository in `core/api/` or the feature's `data/` layer. **The UI never calls Supabase directly** — a `supabase.from(...)` outside a repository is a review blocker.
3. **`CaptureController` is the sole writer of rep events.** Camera frames, landmarks, and state-machine transitions funnel through it; nothing else mutates capture state.
4. **`EvidenceBuilder` is the sole assembler of Evidence.** Exactly one code path turns finished sets into the §evidence shape — which is also why A-18's file dump and the live submit never drift.
5. **Demo context comes from the server.** Demo-board membership is read from server responses (J7); no client flag or provider fabricates it.
