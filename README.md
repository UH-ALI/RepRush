# 🟠 RepRush

### Train anywhere. Claim your ground. 🗺️

[![Flutter](https://img.shields.io/badge/Flutter-app-54C5F8?logo=flutter&logoColor=white)](https://flutter.dev/) [![Supabase](https://img.shields.io/badge/Supabase-backend-3ECF8E?logo=supabase&logoColor=white)](https://supabase.com/) [![On-device ML](https://img.shields.io/badge/Pose%20detection-on--device-FF8A3D?logo=google&logoColor=white)](#-privacy-by-design) [![Status](https://img.shields.io/badge/Status-hackathon%20prototype-F05D5E)](#-project-status)

> 💪 **Your workout is your move.** Turn real movement into territory, progress, and friendly local rivalry.

RepRush turns bodyweight training into a live territory game. Stand in a part of your city, pick an exercise, prop your phone up, and let the camera count your reps. Every clean rep adds power to the hex you're standing in. Get the most power there and the hex is yours, until someone out-trains you.

No equipment. No gym membership. Just movement, ground worth defending, and a reason to come back tomorrow.

## ⚡ How it works

| | Your move |
| --- | --- |
| **1 · 📍 Go somewhere** | The map splits your city into hexes of roughly 0.7 km². You can only train for the hex you're standing in. |
| **2 · 🎯 Choose** | Pick squats, push-ups or pull-ups. |
| **3 · 📱 Train** | Prop your phone up so it can see your whole body. Reps are counted live on the phone, with a buzz for each one. |
| **4 · 🔥 Build power** | The server checks the set and scores it: harder movements, good range of motion and steady tempo count for more. |
| **5 · 🗺️ Claim** | Hold the most power in a hex to own it. Power fades with a 72-hour half-life, so staying on top means staying active. |

## 📱 In the app

- **🗺️ Map:** a dark city map covered in hexes, showing yours, your rivals' and open ones. Your current hex pulses. Tap a hex to see who holds it and with how much power, then train to claim, defend or take it.
- **🏋️ Train:** shows which hex you're in, lets you pick an exercise, and starts a full-screen camera set.
- **🏆 Compete:** a daily challenge for bonus XP, the same for everyone each day, plus a territory leaderboard.
- **👤 Profile:** level and XP, lifetime score, hexes held, rank, and the movement library.
- **🙋 Accounts:** you start playing straight away as a guest, with no signup screen. Pick a display name whenever you like. Add an email and password to keep your progress across phones, or log in to an existing account.

After every set you see your reps, the XP earned, whether you captured the hex or added power, and any level-ups, personal records or newly unlocked movements.

## 🏃 Built for real movement

Calisthenics is the heart of RepRush: it needs no equipment, works in parks and living rooms, and a phone camera can measure it. You progress by learning harder variations, not by lifting heavier weights. The movement library maps out the ladder, and each variation is worth more points:

- 🦵 Assisted squat → squat → jump squat → pistol squat
- 🤸 Knee push-up → push-up → diamond push-up → archer push-up
- 🪜 Dead hang → pull-up → wide-grip pull-up → muscle-up
- ⏱️ Wall sit → plank → side plank → L-sit

The camera currently counts **squats, push-ups and pull-ups**. The other variations appear in the library, and counting for them is on the roadmap.

## 🔒 Privacy by design

Your camera feed never leaves your phone. Pose detection (Google ML Kit) runs on the device and turns movement into measurements: joint angles, confidence and timing. Only those measurements are sent. No video or images are uploaded.

The app never sends a score. The server recomputes every score from the measurements, checks the timing and your location, and only then updates territory. Each workout session can be submitted only once, and every point on the board traces back to a real session.

## 🛠️ Running it

You need Flutter (Dart SDK ^3.12) and a **physical Android or iOS phone**. Camera features don't work in emulators.

```bash
flutter pub get
```

**Offline (demo only):** `flutter run` on its own uses built-in sample data, so you can explore the UI without a backend.

**Live:** pass your Supabase project:

```bash
flutter run \
  --dart-define=REPRUSH_API=live \
  --dart-define=REPRUSH_SUPABASE_URL=https://<project-ref>.supabase.co \
  --dart-define=REPRUSH_SUPABASE_ANON_KEY=<anon-key>
```

A build that carries a key can switch between **Live** and **Demo** in the app: **Profile → Game world**. The choice is remembered across restarts. `REPRUSH_API` only sets which one a fresh install opens in. Demo plays where you're standing, on the real map, owners and leaderboard. Three things are simulated: your sets are scored on the phone and never submitted, nearby players and duels are scripted, and hexes you capture turn yours only on that phone. Nothing in Demo touches a real score. The map shows a **DEMO** tag while it's on. A build with no key gets a fully offline demo world, drawn around you, or around the London venue if location is off.

Optional flags:

| Flag | What it does |
| --- | --- |
| `REPRUSH_STADIA_KEY=<key>` | Sharp, high-resolution dark map tiles from [Stadia Maps](https://stadiamaps.com/) (free tier). Without it the map uses Esri's keyless dark tiles, which are softer on high-density screens. |
| `REPRUSH_DEV_HUD=true` | Developer overlays: FPS, live pipeline panel, raw diagnostics. Off by default in every build mode. |

Pointing at a **local** stack instead? The default URL is `127.0.0.1`, which a phone can't reach. Use your computer's LAN IP, or `10.0.2.2` from an Android emulator.

### Backend (Supabase)

The backend lives in [`supabase/`](supabase/): Postgres migrations and Deno Edge Functions (`session-start`, `session-submit`, `territory`, `me`, `movements`, `challenges`, `presence`, `duels`).

```bash
npx supabase start                                    # local stack (Docker)
cp supabase/functions/.env.example supabase/functions/.env
npx supabase functions serve --env-file supabase/functions/.env
```

`supabase/functions/.env.example` documents each setting. The most important is `LIVE_ENDPOINTS`, which chooses which routes run their real handler instead of canned data. To deploy to a hosted project, run `npx supabase db push`, then `npx supabase functions deploy <name>` for each function, then set the same values as project secrets.

Hosted project settings:
- **Anonymous sign-ins** must be enabled, because guest play depends on them.
- For instant "Save progress", turn **Confirm email** off. Otherwise Supabase emails a confirmation link first.

Demo tooling (Deno):

```bash
deno task seed     # populate the board with rival athletes and territory
deno task reset    # wipe session data back to a clean board
deno task user     # mint a dev account token for scripted submits
deno task submit squat_20_clean   # submit a recorded set end-to-end
SUPABASE_ANON_KEY=<key> deno task nearby   # two fresh athletes: see each other, duel, claim
```

### Checks

```bash
flutter analyze
flutter test                 # app, capture pipeline replay, widgets
node test/server/run_tests.ts   # server scoring, validation, territory (or: deno task test)
dart format .
```

## 🧱 Tech stack

| Layer | Choice |
| --- | --- |
| App | Flutter, Riverpod, `flutter_map` |
| Rep counting | Google ML Kit pose detection (on-device BlazePose, 33 landmarks) → pure-Dart signal smoothing and a rep state machine |
| Location | `geolocator`, H3 hex grid (computed server-side) |
| Backend | Supabase: Postgres, Auth (anonymous plus email), Deno Edge Functions |
| Maps | Stadia Alidade Smooth Dark / Esri Dark Gray Canvas, © OpenStreetMap contributors |

## 🚦 Project status

RepRush is a hackathon prototype. The full loop works against a live backend: train in a hex, the server validates and scores the set, territory and the leaderboard update, XP and levels accrue, and the daily challenge can be claimed.

Coming next:
- **📍 Training spots:** named parks, gyms and pull-up bars, each with its own leaderboard.
- Rep counting for the rest of the movement library.
- Achievements and notifications when someone takes your hex.

Specs and design docs:
- [Product requirements](docs/requirements.md)
- [API and evidence contract](docs/api-contract.md)
- [Team roles and project structure](docs/roles.md)
- [Backend scaffolding](docs/backend-scaffolding.md)

## 🌟 The RepRush promise

Do a workout. Make your mark. Come back and defend it.
