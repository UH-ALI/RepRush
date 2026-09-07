# RepRush

### Train anywhere. Claim your ground.

RepRush turns bodyweight training into a live territory game. Choose a movement, put your phone where it can see you, and let the camera count your reps. Your workout becomes power on the map.

No equipment. No gym membership. Just movement, places worth defending, and a reason to come back tomorrow.

## How it works

1. **Choose a movement** — squat, push-up, pull-up, plank, jumping jack, and more.
2. **Train in view of your phone** — your reps are counted on the device as you move.
3. **Earn power** — good form and harder variations make each workout count for more.
4. **Take your place on the map** — claim the area around you and compete for local training spots.

RepRush has two connected kinds of territory:

| Territory | What it represents | How you claim it |
| --- | --- | --- |
| **Map cells** | Neighbourhood-sized areas | Train anywhere inside the cell |
| **Training spots** | Parks, gyms, pull-up bars, and other places | Train there and rise on its local leaderboard |

Holding a training spot strengthens the map cell around it. Territory gradually cools off over time, so staying on top means staying active.

## Built for real movement

Calisthenics is the heart of RepRush: it needs no equipment, works in parks and living rooms, and can be measured by a phone camera. Progress comes from learning more difficult variations, not lifting heavier weights.

Start with the fundamentals and work your way up:

- Squat to jump squat to pistol squat
- Knee push-up to push-up to diamond push-up
- Dead hang to pull-up to muscle-up
- Wall sit to plank to L-sit

Every session gives you a clear result: reps, a form grade, score, personal records, and a visible effect on the map.

## Privacy by design

Your camera feed stays on your phone. RepRush uses on-device pose detection to turn movement into measurements, then sends only the workout evidence needed to validate your result. No video is uploaded.

Scores are checked before they affect territory or leaderboards, and one workout cannot simply be replayed later. The goal is a competition that feels fair without asking you to give up your privacy.

## Try the project

RepRush is a Flutter project. You will need Flutter installed and a physical Android or iOS device for camera features.

```bash
flutter pub get
flutter run
```

Useful commands while developing:

```bash
flutter analyze
flutter test
dart format .
```

## Project notes

The app is being built as a focused hackathon prototype, with the complete path kept in view: capture a workout, validate it, score it, and update the territory map.

- [Product requirements](docs/requirements.md)
- [API and evidence contract](docs/api-contract.md)
- [Team roles and project structure](docs/roles.md)

## The RepRush promise

Do a workout. Make your mark. Come back and defend it.
