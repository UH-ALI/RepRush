/// Developer-only switches, all OFF unless explicitly asked for at build time.
///
/// Deliberately NOT `kDebugMode`: `flutter run` builds in debug mode, so a
/// debug gate puts tuning overlays on the demo phone the moment someone
/// forgets `--release`. An explicit dart-define means the default build — any
/// mode — is the one judges see.
library;

/// Capture tuning overlays: the FPS chip, the live pipeline panel, the raw
/// Evidence diagnostic on a rejected set, and contract codes on error views.
///
///     flutter run --dart-define=REPRUSH_DEV_HUD=true
const bool showDevHud = bool.fromEnvironment('REPRUSH_DEV_HUD');
