# RepRush — Handoff Context for a New Claude Session

Paste this into a new chat, or tell Claude: **"Read CONTEXT.md, AGENTS.md and docs/ before
doing anything."**

---

## 0. Who / where / how we work

- **Owner:** Rayyan (Windows PC, Claude Desktop app, testing on a real phone).
- **Local clone:** `C:\RepRush`
- **Working branch:** `Ray` (created from `main` at `d3e932b`). All changes go here.
- **Remote:** https://github.com/UH-ALI/RepRush
- **Workflow:** change files locally → test on the phone with `flutter run` → `flutter analyze`
  and `flutter test` → commit → `git push origin Ray`.
- **Rule from the owner:** explain and confirm before changing code. Don't make big changes
  without asking.

---

## 1. What the project is

RepRush is a **Flutter calisthenics territory game**. You stand somewhere in your city, pick an
exercise, prop the phone up, and the camera counts your reps on the device. Clean reps add
**power** to the H3 hex you're standing in (resolution 8, about 0.74 km²). Whoever has the most
power owns the hex. Power decays with a **72-hour half-life**, so owners have to keep training.

- **Privacy promise:** no video or camera frame ever leaves the phone. Only measurements are
  sent: angles, confidence values and timestamps.
- **Integrity promise:** the client **never sends a score**. The server recomputes everything
  from the measurements.
- **Status:** hackathon prototype, built by 3 developers on parallel tracks:
  - **A, Capture:** `lib/features/capture/`, plus the platform configs.
  - **B, Core/backend:** `lib/core/api`, `lib/models`, `supabase/`.
  - **C, UI:** `lib/app`, `lib/features/*/ui`, `lib/shared`.

### Tech stack
- **App:** Flutter (Dart ^3.12.1), Riverpod 3, flutter_map, geolocator, camera ^0.12.1,
  `google_mlkit_pose_detection` (with a local override in `packages/`, see §3).
- **Backend:** Supabase (Postgres, Auth with anonymous and email sign-in, Deno Edge
  Functions).
- **Edge functions:** `session-start`, `session-submit`, `territory`, `me`, `movements`,
  `challenges`, `presence`, `duels`.
- **Migrations:** `supabase/migrations/0001`–`0010`. `0010_hex_history` is the newest.

### App tabs
- **Map:** hexes; tap one to see its owner, power and recent activity.
- **Train:** pick an exercise and start a camera set.
- **Compete:** daily challenge, leaderboards, duels with nearby players.
- **Profile:** XP, level, movement library, and the Live/Demo switch under "Game world".

### Live vs Demo
- **Live:** everything comes from the server.
- **Demo in a build that has a key:** the real map and owners, but your sets are scored on
  the phone and never submitted, and nearby players and duels are scripted.
  Code: `lib/core/api/demo/demo_repositories.dart`.
- **Build with no key:** fully offline stub world (`lib/core/api/stub/stub_repositories.dart`).

---

## 2. One full round of the game

1. The app sends GPS to `POST /session-start`. The server checks accuracy (≤ 50 m), rejects
   mocked GPS, rejects "teleports" (> 40 km/h since the last session), computes the H3 hex,
   and returns a **one-time sessionId** plus `movementConfigVersion`.
2. The user trains. The phone counts reps live (see §3).
3. The user taps **Finish**. The app builds an **Evidence** JSON and sends
   `POST /session-submit`.
4. The server validates the submission, recomputes the score, writes an append-only ledger,
   resolves hex ownership, and returns XP, level-ups, capture results and challenge progress.

---

## 3. How the AI works

**There is exactly ONE machine-learning model: Google ML Kit Pose Detection**, the
BlazePose-based **"base"** model, running in **stream mode** on the device. There is no LLM and
no other ML. Everything after the model is hand-written signal processing and rules.

- **Model output per frame:** 33 landmarks, each with `x`, `y` (pixels), `z`, and an
  `inFrameLikelihood` between 0 and 1.
- **Local plugin override:** `packages/google_mlkit_pose_detection`. On Android it now sends
  2D pixel `position.x/y` instead of 3D world coordinates.

### The pipeline: `lib/features/capture/pipeline/`
This folder must stay **pure Dart**: no Flutter imports and no plugins. That's what lets the
replay tests run fast.

| Step | File | What it does |
|---|---|---|
| Camera to ML Kit | `camera/input_image_adapter.dart`, `camera/pose_service.dart`, `camera/coordinates.dart` | Sends NV21 frames with the rotation formula applied. If inference is busy, the frame is dropped, never queued; drops are counted in `framesDropped`. |
| Side selection | `side_selector.dart` | Picks the left or right 3-point chain (leg: hip-knee-ankle; arm: shoulder-elbow-wrist). It uses the side whose weakest point is most visible (floor 0.5), drops points outside the image, and only switches sides when the other side is better by 0.10. |
| Angle | `angle_math.dart` | 2D joint angle at the knee or elbow, via `atan2`. |
| Smoothing | `ema_filter.dart` | EMA with alpha 0.35 (one-euro filter is the planned upgrade). |
| Calibration | `calibration.dart` | Collects about 30 frames (~2 s) of standing still. The median becomes `restSignal`. It's rejected if the median falls outside 145–184° or the p10–p90 spread is over 8° (12° for pull-ups). All thresholds = `restSignal + offset`. It also records `torsoLengthPx` and `shoulderWidthPx`. |
| Rep state machine | `rep_machine.dart` | REST → DESCENDING → DEPTH_REACHED → ASCENDING → REST, which emits a rep. Hysteresis plus a disarm/re-arm guard prevents double counts. A "shallow attempt" is recorded locally only. Losing tracking for 15 frames mid-rep discards the rep. |
| Coaching | `feedback.dart` | Green/amber/red cues, debounced over 3 frames. "Shallow" and "rep counted" cues show immediately. The phone vibrates once per rep (UI). |
| Orchestrator | `rep_pipeline.dart` | Chains every step above, one `tick()` per frame. |
| Evidence | `evidence.dart` | Builds the JSON the server expects. It refuses to build if any score field is present. Rep `i` is 0-based. |
| Controller | `lib/features/capture/data/capture_controller.dart` | Camera lifecycle, session stopwatch (all `*Ms` values are offsets from session start, never epoch times), collects reps, and `finishSet()` builds the Evidence. |

### Movement configs (`movement_config.dart`)
Only these 3 can be counted today. The list lives in `captureReadyConfigs` in
`lib/features/session/ui/training_flow.dart`.

| Movement | Chain | startDescent | enterPeak | enterRest | romTarget | Status |
|---|---|---|---|---|---|---|
| squat | leg | −12 | −65 | −25 | −95 | tested on synthetic data only |
| push_up | arm | −8 | −70 | −20 | −90 | **UNTUNED** |
| pull_up | arm | −8 | −70 | −20 | −90 | **UNTUNED** (copied from push-up) |

All offsets are in degrees relative to the calibrated rest angle. For a squat with rest at 175°:
descent starts at 163°, 110° counts as depth, passing 150° on the way up counts the rep, and
80° is full range of motion.

---

## 4. Server logic (`supabase/functions/_shared/`)

These are rules, not AI.

### Hard rejections (`validation/session.ts`)
These return a 4xx and **don't** use up the session:
- unknown session, or one owned by someone else
- session already used, or expired (4 h window)
- config version mismatch
- mocked GPS on the production board
- spot mismatch
- Evidence location more than 100 m from the start fix
- **wall-clock check:** the claimed set duration must fit inside the time the server actually
  observed, plus 5 s of slack

### Score (`scoring/`)
- **RepScore** = `reps × difficulty × formFactor × tempoFactor`
  - **formFactor** = `0.6 + 0.4 × (0.6 × romScore + 0.4 × confScore)`, so between 0.6 and
    1.0.
    - `romScore = clamp((peak − enterPeak) / (romTarget − enterPeak), 0, 1)`
    - `confScore = clamp(confMean / 0.70, 0, 1)`
    - Kip dock (B18) and pull-up "not confirmed" ×0.75 (B16) apply only if the client sends
      `hipDriftNorm` / `shoulderWristDyNorm`. **It doesn't (see gaps).**
  - **tempoFactor** is between 0.5 and 1.0. A median rep cycle under 900 ms forces 0.5. Too
    uniform a cadence (CV < 0.06) and no fatigue slowdown (10+ reps) are penalised too.
- **Holds:** `(seconds / 3) × discount × difficulty × formFactor`. Exists on the server only;
  the client has no hold counter.
- **Caps:** 150 points per set; daily score above 600 earns ×0.5, above 1200 earns ×0.25;
  at most 20 sessions per day.
- **Difficulty** (migration `0002`): squat 1.0, push_up 1.0, pull_up 1.8; the scale runs
  0.7–3.0.
- **Shadow flags** (`flags.ts`, `validation/trace.ts`): recorded only, never block a
  submission. A human voids sessions later.

### Territory (`territory.ts`)
- Each set's contribution is stored once and never changed.
- Current power = `Σ amount × 0.5^(age / 72 h)`, computed when read.
- Minimum power to claim a hex: 10 (`REPRUSH_MIN_CLAIM_POWER`).
- Territory is earned only if start GPS accuracy is ≤ 50 m and the location isn't mocked.

### Server thresholds (`supabase/migrations/0003_config_versions.sql`, version `2026-08-30.1`)
| Movement | enterPeak | enterRest | romTarget |
|---|---|---|---|
| squat | −65 | −25 | −95 |
| push_up | −55 | −20 | −80 |
| pull_up | −85 | −25 | −120 |

---

## 5. Known gaps, ranked (verified against `Ray` @ d3e932b)

1. **Squat placement text contradicts itself, which can break counting live.**
   - In `lib/features/capture/pipeline/movement_config.dart`, the default `placementGuidance`
     (shown during calibration) says *"Face the camera…"*, but `retryImplausibleRest` says
     *"Stand side-on…"*.
   - A 2D knee angle barely changes when you squat facing the camera. **Squats must be filmed
     side-on.**
   - **Fix:** make all squat cues say side-on.

2. **iOS crashes when the camera opens.**
   - `ios/Runner/Info.plist` has no `NSCameraUsageDescription`.
   - The iOS deployment target is `13.0` in `ios/Runner.xcodeproj/project.pbxproj`. ML Kit
     needs about 15.5.
   - There's no `ios/Podfile`; Flutter creates it on the first build, and it needs
     `platform :ios, '15.5'`.

3. **Push-up and pull-up accuracy is unproven.**
   - Their thresholds are marked `UNTUNED`.
   - All replay fixtures in `test/capture/fixtures/` are **synthetic squats** generated by
     `tool/gen_fixtures.dart`. There are no real phone recordings.
   - The project's own acceptance target is **±1 rep on a 20-rep set** across 3 body types
     and 2 lighting conditions.
   - **Fix:** record real sets with the debug `TraceRecorder` (`debugTraceJson()` in
     `capture_controller.dart`), add them as fixtures, and tune the thresholds.

4. **Client and server thresholds disagree** for push-ups and pull-ups (compare §3 and §4).
   - For pull-ups the client counts at rest−70° but the server's depth line is rest−85°. Reps
     between those two get `romScore = 0`.
   - **Fix:** agree on one set of values. Changing the server values means a new config
     version row (old versions are frozen).

5. **Anti-cheat cross-check is dormant.**
   - The client never sends the ~5 Hz `trace` (`{hz, t0Ms, primary[], confMean[]}`), so
     every session gets only `TRACE_MISSING` and the trace checks never run.
   - The client also never sends `hipDriftNorm` or `shoulderWristDyNorm`, so the pull-up kip
     and confirmation checks never run either.
   - Today the server recomputes the score from summary numbers the client chose. Replay
     protection, the wall-clock check and the GPS gates **do** work.

6. **Risks to verify with real data (not confirmed):**
   - **Fast honest reps may score as "impossible".** The client's rep cycle is measured from
     the startDescent crossing to the enterRest crossing, which is shorter than the full rep.
     Quick push-ups could fall under the server's 900 ms floor in `scoring/tempo.ts` and get
     tempoFactor 0.5.
   - **Fast reps may lose depth.** EMA lag at ~15 fps can make the bottom of a fast rep look
     shallower, which risks undercounting.
   - **Model choice:** only the `base` model is used. `accurate` is the documented fallback,
     and `modelVariant` is hard-coded to `'base'` in `evidence.dart`.

7. **Cleanup:**
   - Debug code marked "Temporary — remove before shipping" in `capture_controller.dart`:
     the `[CoordSpace]` logging, `_calibDiagLogged`, and `lastFinishDiagnostic`.
   - The `pubspec.yaml` comment says camera is pinned to 0.11.x, but it's `^0.12.1`.
   - Not built yet: Spots (no table), achievements, notifications, client-side hold counting
     (plank), and TTS (AGENTS.md mentions flutter_tts; the app uses haptics).

**Suggested order:** 1 → 2 (if demoing on iPhone) → 3 → 4 → 5 → 7.

---

## 6. Setup and commands

### On Rayyan's Windows PC
```powershell
cd C:\RepRush
git checkout Ray
git pull origin Ray
flutter pub get
flutter devices                 # Android phone with USB debugging on
flutter run                     # demo/offline mode, no backend needed
```

### Live mode (hosted Supabase project)
Supabase dashboard settings:
- Anonymous sign-ins **ON**.
- Confirm email **OFF**.

Deploy:
```bash
npx supabase login
npx supabase link --project-ref <ref>
npx supabase db push
for f in session-start session-submit territory me movements challenges presence duels; do npx supabase functions deploy $f; done
npx supabase secrets set LIVE_ENDPOINTS=session-start,session-submit,territory,me,challenges,presence,duels REPRUSH_MIN_CLAIM_POWER=10 REPRUSH_DAILY_MOVEMENT=squat REPRUSH_DAILY_TARGET=30
```

Run the app against the project:
```bash
flutter run --dart-define=REPRUSH_API=live \
  --dart-define=REPRUSH_SUPABASE_URL=https://<ref>.supabase.co \
  --dart-define=REPRUSH_SUPABASE_ANON_KEY=<anon-key>
```

Notes:
- `verify_jwt = false` is set for all 8 functions in `supabase/config.toml`. Keep it.
- Any route not in `LIVE_ENDPOINTS` returns canned stub data.
- Optional: `REPRUSH_STADIA_KEY` for sharper map tiles; `REPRUSH_DEV_HUD=true` for the
  pipeline debug overlay.
- Shareable APK: `flutter build apk --release` with the same `--dart-define`s. The output is
  `build/app/outputs/flutter-apk/app-release.apk`. It's signed with the debug key, which is
  fine for sideloading.

### Checks
```bash
flutter analyze
flutter test                        # app, capture replay, widgets
node test/server/run_tests.ts       # server: 328/328 passed at bb581c9 (or: deno task test)
dart format .
```

Demo tooling (Deno): `deno task seed | reset | user | submit <fixture> | nearby`.

### Using the app (important for demos)
- Allow camera and **precise** location.
- Train outdoors so GPS accuracy is ≤ 50 m.
- Get your full body in frame. **Squats side-on**; push-ups and pull-ups with the camera to
  the side.
- Stand still about 2 s for calibration, wait for "Ready", do reps, tap **Finish**.

---

## 7. Rules that must not be broken (from AGENTS.md / docs)

- `capture/pipeline/` stays pure Dart.
- Never add `score`, `repScore`, `xp`, `formFactor`, `romScore`, `tempoFactor` or `points` to
  Evidence. The server rejects them.
- No pixel fields in rep records. Distances are normalised (`*Norm`); raw pixels belong only in
  `calibration`.
- H3 is computed only on the server.
- Sessions are one-shot.
- Shadow-flag, don't hard-ban.
- Movement difficulty values are frozen. Threshold changes on the server need a new
  `movement_config_offsets` version.
- Specs: `docs/requirements.md`, `docs/api-contract.md` (the Evidence schema is the most
  important part), `docs/roles.md`, `docs/backend-scaffolding.md`.

---

## 8. Presentation talking points

- **"Where's the AI?"** On-device pose estimation (ML Kit BlazePose, 33 landmarks), followed
  by a deterministic, explainable signal pipeline: per-user calibration, smoothing, and a
  hysteresis state machine. It runs in real time with no cloud and no video upload.
- **Anti-cheat honesty:** replay is impossible (one-shot sessions plus the wall-clock check),
  GPS is verified, and scores are recomputed on the server. The trace cross-check is built on
  the server but **not yet fed by the client**. Say "designed for", not "enforced".
- **Safest live demo:** squats on Android, filmed side-on, in good light.
