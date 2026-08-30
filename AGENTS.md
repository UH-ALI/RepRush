# AGENTS.md

This file provides guidance to Qoder (qoder.com) when working with code in this repository.

## Project Overview

RepRush is a Flutter calisthenics territory game. Users perform exercises while their phone's camera counts reps using on-device pose detection (Google ML Kit). Scores capture real-world territory on two scales: H3 hex cells (~0.74 km²) and named Spots (gyms, parks, bars). Power decays with a 72-hour half-life. The app is designed for a 7-day hackathon with 3 developers on parallel tracks.

**Privacy guarantee:** No video or camera frame ever leaves the device. Only derived measurements (angles, confidences, timestamps) are transmitted.

## Build & Development Commands

```bash
# Install dependencies
flutter pub get

# Run the app (specify a device for camera features — simulator won't work for capture)
flutter run

# Run with hot reload (press 'r' to reload, 'R' to restart)
flutter run --hot

# Analyze / lint
flutter analyze

# Run all tests
flutter test

# Run a single test file
flutter test test/path/to/test_file.dart

# Run a single test by name
flutter test --plain-name "test name pattern"

# Format code
dart format .

# Check for outdated dependencies
flutter pub outdated
```

## Tech Stack

- **Flutter** (Dart SDK ^3.12.1, Flutter >=3.18.0)
- **Google ML Kit** (`google_mlkit_pose_detection`) — on-device BlazePose, 33 landmarks
- **Supabase** (PostgreSQL + PostGIS + Realtime) via `supabase_flutter`
- **flutter_map** for map rendering (not google_maps_flutter — polygon performance)
- **geolocator** for location (exposes accuracy and `isMocked`)
- **flutter_tts** for audio rep cues
- **State management:** TBD (Riverpod suggested) — check `docs/api-contract.md` §state

## Architecture

### Three Development Tracks

The project is built by 3 developers on parallel tracks with strict ownership boundaries:

| Track | Scope | Key directories |
|-------|-------|-----------------|
| **A — Capture** | Camera → pose landmarks → Evidence object | `lib/features/capture/`, `android/`, `ios/` platform config |
| **B — Core** | Schema, scoring, ledger, territory, APIs, integrity | `lib/core/auth/`, `lib/core/api/`, `lib/models/`, `supabase/` |
| **C — Surface** | App shell, UI screens, map, navigation, demo mode | `lib/app/`, `lib/features/*/ui/`, `lib/shared/` |

### The Evidence Contract (Central Seam)

Evidence is **the single interface between all three tracks**. Defined in `docs/api-contract.md` §evidence.

- **Track A** produces Evidence (landmarks in, Evidence out)
- **Track B** consumes Evidence for scoring, validation, and ledger writes
- **Track C** consumes Evidence as a typed model for UI display

Evidence has three granularities: **set** (movement, timing, calibration), **rep** (per-rep measurements), **trace** (~5 Hz downsampled signal for server-side cross-validation).

**Critical rule:** The client never sends a score. It sends evidence; the server recomputes all scores.

### The Purity Rule for `capture/pipeline/`

`lib/features/capture/pipeline/` **must be pure Dart** — no Flutter imports, no plugins, no `dart:ui`. This directory contains the signal conditioning, rep state machine, and evidence assembly. This purity constraint is what makes the replay test suite (recorded landmark traces → assert ±1 rep) run in sub-second without a device rebuild.

If something in `pipeline/` needs a widget or plugin, it belongs in `capture/camera/` or `capture/ui/` instead.

### Repo Layout & Ownership

```
lib/
  main.dart                       # Track C — entry point
  app/                            # C — router, theme, tokens, priming
  core/
    auth/                         # B
    api/                          # B — API clients
    demo_mode.dart                # C
    telemetry/                    # C
  models/                         # B — shared types from API contract
  features/
    capture/
      camera/                     # A — frames → landmarks (plugins, ML Kit)
      pipeline/                   # A — landmarks → Evidence (PURE DART)
      ui/                         # A — HUD, framing, placement cards, audio
    session/ui/                   # C — summary screen
    territory/data/               # B
    territory/ui/                 # C
    spots/data/                   # B
    spots/ui/                     # C
    progression/data/             # B
    progression/ui/               # C
    notifications/                # C
  shared/                         # C — reusable widgets, empty/error states
supabase/
  migrations/                     # B
  functions/                      # B — edge functions (scoring, territory, etc.)
  seed/                           # B
```

Inside every feature, `data/` is Track B's and `ui/` is Track C's. `capture/` is the exception — it belongs entirely to Track A.

### Scoring Formula

```
RepScore = reps × difficulty × formFactor × tempoFactor
```

- `difficulty` — movement tier multiplier (0.7–3.0), frozen Day 1
- `formFactor` — `0.60 + 0.40 × (0.60 × romScore + 0.40 × confScore)`, range [0.6, 1.0]
- `tempoFactor` — penalises robotic or impossible cadence, range [0.5, 1.0]
- Holds convert: `(seconds / 3) × difficulty × formFactor`

**Server recomputes all of this** — never add `score`, `xp`, or `formFactor` fields to the Evidence payload.

### Rep State Machine

Two states: `REST` and `PEAK`. A rep is emitted when the athlete returns to rest having passed through peak. Two thresholds (`enterPeak` / `enterRest`) create a hysteresis band preventing double-counting at turnarounds. Smoothing (EMA or one-euro filter) is mandatory upstream of the state machine.

### Key Domain Rules

- **One-shot sessions:** `/session/start` issues a server-generated ID; submitting consumes it. No replays.
- **Append-only score ledger:** Every point traces to a session. Flagged sessions are voided; boards recompute.
- **No pixel measurements in rep records.** Every distance field is normalised (`hipDriftNorm`, `shoulderWristDyNorm`, `ankleSepNorm`) against a calibration reference. Raw pixels live in `calibration` only.
- **H3 hexes computed server-side.** The client draws plain coordinate polygons — no H3 library needed on the client.
- **Spot verification:** User-created spots are `unverified` and score nothing until 3 distinct users have trained there.

## Documentation

All specification lives in `docs/`:
- `docs/requirements.md` — full requirements (MoSCoW prioritized), domain model, 7-day plan, risk register
- `docs/api-contract.md` — Evidence schema, movement threshold table, scoring formulas, endpoint register
- `docs/roles.md` — track ownership, deliverable register, file-level ownership map, seam contracts

Read these before making architectural decisions. The Evidence schema in `api-contract.md` is the most load-bearing artifact in the repo.

## Key Decisions Already Made

- **Calisthenics only** — no barbells, no wearables. This is the defining constraint, not a scope cut.
- **No automatic movement recognition** — user picks the exercise before each set.
- **One demo phone** — test on the real device daily, not a simulator. Camera features don't work on simulators.
- **Day 6 noon freeze** — no OTA updates available; Day 7 is rehearsal only.
- **Shadow-flag, don't hard-ban** — during a hackathon, false-positive lockouts are worse than cheaters.
- **Cut order when behind:** challenges → achievements → higher tiers → decay → notifications. Never cut a whole scale.
