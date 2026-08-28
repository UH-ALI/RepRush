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

On emit, the accumulated rep record is already complete: start/end timestamps, the rest-side extreme before departure, the peak-side extreme reached, mean and min confidence of the landmarks forming the signal, and the concentric/eccentric split.

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
| Squat, trough 95° | `(95−110)/(80−110)` | 0.50 |
| Squat, trough 78° | `(78−110)/(80−110)` = 1.07 | 1.00 (capped) |
| Pull-up, trough 52.8° | `(52.8−90)/(55−90)` = 1.06 | 1.00 |
| Jumping jack, peak 1.45 | `(1.45−1.20)/(1.60−1.20)` | 0.63 |

### formFactor

```
confScore  = clamp( confMean / 0.70, 0, 1 )
formFactor = 0.60 + 0.40 × ( 0.60 × romScore + 0.40 × confScore )
```

Lands in **[0.6, 1.0]**, matching [requirements.md §4](requirements.md). Penalties (kip/swing, B18) apply multiplicatively on top.

`confScore` is floored rather than linear on purpose: at `confMean ≥ 0.70` it contributes 1.0 and never bites. Good lighting is never rewarded, but poor lighting degrades gracefully instead of scaling from zero. B7 requires low-confidence reps to count-but-be-penalised; this is the mildest reading of that which still satisfies it.

Set-level `formFactor` is the mean across reps. **The server recomputes all of this** — the client sends `troughAngleDeg` and `confMean`, never a `formFactor` and never a score (I1).

### Holds

A different mechanic — **no state machine**. Per frame, evaluate the in-form predicate (plank: trunk angle within 160–185°) and accumulate time while true. Output is `holdSegments`, not reps.

**Open decision for B:** is 3 × 20 s worth the same as 1 × 60 s? If segments simply sum, micro-breaks are free and the movement is gameable. Suggested default — only segments ≥ 5 s count, and total is discounted by segment count. Settle this when the hold-to-rep conversion is sanity-checked on Day 4.

### Calibration — captured during the 3-2-1 countdown

The largest threat to fixed absolute thresholds is that **a 2D joint angle depends on viewing angle**. A knee measured 45° off-axis does not read the same degrees as one measured side-on.

Three mitigations, all of which should ship: placement cards force a consistent view (A-12), the framing check can reject a bad one (A-9), and — the cheap strong one — **capture a calibration frame during the countdown**. Record the athlete's rest-pose angles and body scale, then express thresholds relative to their own start pose. That absorbs body proportions and camera-angle drift in a single move.

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

    "clientRepCount": 10,           // reconciliation only — never trusted
    "manualAdjustment": 0           // B8 — recorded, not silently applied
  }]
}
```

**The client never sends a score.** If a PR adds a `score`, `xp`, or `formFactor` field here, reject it (I1).

### What the server can actually verify

Three levels, and the ceiling is worth stating plainly to the team so nobody oversells it on stage.

**1 · Recompute.** The server recomputes `romScore`, `formFactor` and `RepScore` from the uploaded numbers. This satisfies I1 — but it is recomputation from client-supplied *measurements*.

**2 · Cross-check the summary against the trace.** This is the check that earns its keep. Per rep window `[tStartMs, tEndMs]`, take the extreme of `trace.primary` over that window:

- `peakExtreme` must be **at least as extreme** as the trace extreme — 5 Hz sampling can only *miss* the true peak, never overshoot it
- …and within tolerance of it (**15°**, or 0.15 for ratio signals). A rep claiming a 52° trough when the trace bottoms out at 110° is a contradiction
- Threshold crossings counted directly in `trace.primary` must be within ±1 of `reps.length`

A forger now has to fake **two representations coherently**, which is a materially different problem from faking twenty numbers.

**3 · What is not verifiable.** The server cannot confirm a human was in front of the camera. Nothing can — see [requirements.md §6-I](requirements.md). Attestation raises the cost, caps bound the daily winnings, decay makes stolen territory expensive to hold, and the append-only ledger makes cleanup retroactive. That is the whole defence and it is the same one Strava and Zwift run.

So: **form is not verified, it is gated and graded.** Measurement correctness is checkable only for internal consistency.

### Under consideration — raw landmarks at 5 Hz

Shipping the raw 33 landmarks alongside the derived values costs roughly 150 KB of JSON per set before compression, and buys the ability for B to derive a signal A never emitted — **server-side, with no client rebuild**.

Given the project has no OTA safety net and freezes Day 6 at noon, that is cheap insurance against a named risk. Recommended if the payload size holds up on the venue network. Decide by Day 5.

---

## §endpoints

*B-3 — see the endpoint register in [roles.md §4 Seam 2](roles.md#4-the-seams--where-two-people-meet). Stubbed responses with realistic fake data due end of Day 1.*

---

## §state

*C-3 — state-management convention, decided Day 1 with all three in the room.*
