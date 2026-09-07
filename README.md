# 🟠 RepRush

### Train anywhere. Claim your ground. 🗺️

[![Flutter](https://img.shields.io/badge/Flutter-app-54C5F8?logo=flutter&logoColor=white)](https://flutter.dev/) [![Camera powered](https://img.shields.io/badge/Camera-powered-FF8A3D?logo=googlecamera&logoColor=white)](#how-it-works) [![Privacy first](https://img.shields.io/badge/Privacy-first-20B486?logo=shield&logoColor=white)](#privacy-by-design) [![Status](https://img.shields.io/badge/Status-hackathon%20prototype-F05D5E)](#project-notes)

> 💪 **Your workout is your move.** Turn real movement into territory, progress, and friendly local rivalry.

RepRush turns bodyweight training into a live territory game. Choose a movement, put your phone where it can see you, and let the camera count your reps. Your workout becomes power on the map.

No equipment. No gym membership. Just movement, places worth defending, and a reason to come back tomorrow.

## ⚡ How it works

| | Your move |
| --- | --- |
| **1 · 🎯 Choose** | Pick a movement: squat, push-up, pull-up, plank, jumping jack, and more. |
| **2 · 📱 Train** | Put your phone where it can see you. Your reps are counted as you move. |
| **3 · 🔥 Build power** | Good form and harder variations make every workout count for more. |
| **4 · 🗺️ Claim** | Capture the area around you and compete for local training spots. |

RepRush has two connected kinds of territory:

| Territory | What it represents | How you claim it |
| --- | --- | --- |
| **🟧 Map cells** | Neighbourhood-sized areas | Train anywhere inside the cell |
| **📍 Training spots** | Parks, gyms, pull-up bars, and other places | Train there and rise on its local leaderboard |

> 🏆 **Hold the spot, strengthen the cell.** Territory gradually cools off over time, so staying on top means staying active.

## 🏃 Built for real movement

Calisthenics is the heart of RepRush: it needs no equipment, works in parks and living rooms, and can be measured by a phone camera. Progress comes from learning more difficult variations, not lifting heavier weights.

Start with the fundamentals and work your way up:

- 🦵 Squat → jump squat → pistol squat
- 🤸 Knee push-up → push-up → diamond push-up
- 🪜 Dead hang → pull-up → muscle-up
- ⏱️ Wall sit → plank → L-sit

Every session gives you a clear result: reps, a form grade, score, personal records, and a visible effect on the map.

## 🔒 Privacy by design

Your camera feed stays on your phone. RepRush uses on-device pose detection to turn movement into measurements, then sends only the workout evidence needed to validate your result. No video is uploaded.

Scores are checked before they affect territory or leaderboards, and one workout cannot simply be replayed later. The goal is a competition that feels fair without asking you to give up your privacy.

## 🛠️ Try the project

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

## 📚 Project notes

The app is being built as a focused hackathon prototype, with the complete path kept in view: capture a workout, validate it, score it, and update the territory map.

- [Product requirements](docs/requirements.md)
- [API and evidence contract](docs/api-contract.md)
- [Team roles and project structure](docs/roles.md)

## 🌟 The RepRush promise

Do a workout. Make your mark. Come back and defend it.
