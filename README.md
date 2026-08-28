# RepRush

**A territory game you play with your body.**
No equipment, no gym membership, no honour system — the camera is the referee.

> Point your phone at yourself, do pull-ups, and claim the map.

---

## The idea

You do calisthenics. Your phone counts every rep with on-device pose detection and turns it into a score.

That score does two things: it **captures territory** on a real-world map, and it makes you **the name on the board** at the bar or gym you train at.

---

## Two loops, one mechanic

Both scales use identical rules — same power, same decay, same capture condition. Only the geography differs.

| | **Hexes** | **Spots** |
|---|---|---|
| What | ~0.74 km² cells covering the city | Pull-up bars, calisthenics parks, gyms |
| Feel | Anonymous, adversarial | Social — you see the same faces |
| Claim by | Training anywhere inside | Training while checked in |

**They feed each other:** every spot you hold adds power to the hex around it. Grind the open cell, or go take the rig inside it and get both.

**Power decays with a 72-hour half-life.** You can't win once and retire — that's the whole retention model.

---

## Why calisthenics only

Not a scope cut. It's what makes the two loops one product.

- **Barbells are location-fixed.** You lift in one spot, standing still. A barbell user could never play a territory game. Calisthenics is mobile by nature.
- **A camera can't see what's on a bar** — but it can see everything in calisthenics. Every scored rep is verifiable.
- **The privacy claim goes absolute:** no video ever leaves your device. No exceptions.
- **The sport already built the progression system.** Knee push-up → push-up → diamond → archer → one-arm.
- **Zero equipment** means a judge can try it in the next sixty seconds.

---

## Scoring

One currency. Everything reads the same number.

```
RepScore = reps × difficulty × formFactor × tempoFactor
```

- **difficulty** — from the movement tree below
- **formFactor** — pose confidence × range of motion
- **tempoFactor** — penalises robotic or impossible cadence

Holds convert at 3 seconds ≈ 1 rep. The timer only runs while your form holds, so a sagging plank stops earning.

---

## The movements

| Family | T1 | T2 | T3 | T4 |
|---|---|---|---|---|
| **Squat** | Assisted `0.7` | **Squat `1.0`** | Jump squat `1.5` | Pistol `2.4` |
| **Push** | Knee `0.7` | **Push-up `1.0`** | Diamond `1.4` | Archer `2.0` |
| **Pull** | Dead hang `0.8` | **Pull-up `1.8`** | Wide-grip `2.2` | Muscle-up `3.0` |
| **Hold** | Wall sit `0.8` | **Plank `1.0`** | Side plank `1.3` | L-sit `2.2` |
| **Jump** | — | **Jumping jack `0.8`** | Burpee `2.2` | — |

**Bold = ships this week.** T1 and T2 are available immediately; T3+ unlock by doing 50 verified reps of the tier below.

Harder variations score more. That's progression, difficulty, and anti-cheat in one system.

---

## "Can't people just cheat?"

The camera feed never leaves the device, so the server can't *prove* a workout happened. Nobody's can — Strava and Zwift live here too. The goal isn't uncheatable, it's **expensive, detectable, and reversible.**

| Attack | Answer |
|---|---|
| Replay a captured API call | **Dead.** Sessions are one-shot and server-timed |
| Script a fake payload | Device attestation — now you need a rooted phone |
| Fake your GPS | Mock-location detection, accuracy gate, teleport check |
| Synthesise a fake pose trace | We store the full angle time-series. Faking correlated human noise and fatigue drift is hard |

Because there are no weights, **nothing in the scoring path is a typed number.** Nothing to inflate. Every point is camera-derived.

And every score sits in an append-only ledger — flag a session later and every board recomputes.

---

## Stack

**Flutter** · ML Kit pose detection (on-device) · Supabase (Postgres + PostGIS + realtime) · `flutter_map` · H3 hexes computed server-side

---

## The week

Three people, three tracks: **A** capture · **B** backend · **C** surface.

| Day | What |
|---|---|
| 1 | Spikes. Camera → pose landmarks on a real phone. B publishes stubbed APIs so C is never blocked |
| 2 | **Gate: ±1 rep on a 20-rep set.** Pass or we fall back to manual entry |
| 3 | Integration. Push-up → pull-up → plank → jumping jack. A real workout flips a real hex |
| 4 | Spots: check-in, capture, boards, PRs |
| 5 | Progression, challenges, notifications, thermal test |
| 6 | Attestation, validators, seed data, demo mode. **Freeze at noon** |
| 7 | Rehearse. Zero planned coding |

---

## The demo

90 seconds, one continuous take, nothing mocked:

1. Open the app → contested hexes and spot pins around you
2. Start a session → prop the phone → **10 pull-ups**, counted live with voice
3. Summary: reps, score, form grade, a new PR
4. The map flips — hex and spot both turn your colour
5. The spot's board moves you to the top
6. Level up

---

📄 **Full specification:** [docs/requirements.md](docs/requirements.md) — scope, domain model, every requirement, the seven-day plan, and the risk register.

👥 **Who builds what:** [docs/roles.md](docs/roles.md) — track ownership, the deliverable register, file-level ownership map, and the three contracts between tracks.
