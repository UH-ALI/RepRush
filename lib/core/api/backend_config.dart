/// Which backend the app talks to, and how to reach it.
///
/// Ownership: B.
///
/// Every value here is a compile-time `--dart-define`. There is deliberately no
/// settings screen and no secrets file: a dart-define is baked into the artefact,
/// so "the demo build" and "my dev build" are two different binaries rather than
/// one binary pointed at different servers by a mutable flag nobody remembers the
/// state of. On demo day that is the difference between knowing which backend you
/// are talking to and finding out on stage.
///
/// The default is [ApiMode.live]. The app therefore reads territory from the
/// Supabase Edge Functions unless a developer explicitly opts into stub mode.
/// Going live needs the Supabase publishable/anon key:
///
///     flutter run --dart-define=REPRUSH_API=live \
///                 --dart-define=REPRUSH_SUPABASE_ANON_KEY=<key>
///
/// THE URL IS THE FLAG THAT IS MOST OFTEN WRONG
/// The default is the machine's own loopback — right for a desktop build, wrong
/// everywhere else:
///
///   - Android emulator: the host machine is `10.0.2.2`, not `127.0.0.1`.
///   - Physical device, i.e. the demo phone: the machine's LAN IP, with the phone
///     on the same network as the stack. `npx supabase start` binds `0.0.0.0`, so
///     the LAN IP works; loopback does not.
///
/// Android also refuses cleartext HTTP by default and a local stack is HTTP.
/// `android/app/src/debug/AndroidManifest.xml` opts the DEBUG build out of that.
/// A release build does not, and should not — it talks to a hosted HTTPS project.
library;

import 'package:flutter/foundation.dart';

/// Which implementation the repository providers bind to.
enum ApiMode {
  /// The in-process fakes in `stub/`.
  stub,

  /// The Supabase Edge Functions in `supabase/functions/`.
  live;

  /// Parses `REPRUSH_API`.
  ///
  /// An unrecognised value is an error that names the two which work. The
  /// alternative — defaulting to [stub] — fails as "the app is still using
  /// stubs", which is true and no help at all in finding the typo that caused it.
  static ApiMode parse(String raw) => switch (raw.trim().toLowerCase()) {
    'stub' => ApiMode.stub,
    'live' => ApiMode.live,
    _ => throw StateError(
      'REPRUSH_API="$raw" is not a mode. Pass stub or live.',
    ),
  };
}

@immutable
class BackendConfig {
  const BackendConfig({
    required this.mode,
    required this.supabaseUrl,
    required this.anonKey,
    this.devEmail,
    this.devPassword,
  });

  /// The local stack's API port (`[api] port` in `supabase/config.toml`). Kong
  /// serves both `/auth/v1` and `/functions/v1` from here, so this one URL is the
  /// whole backend as far as the client is concerned.
  static const defaultSupabaseUrl = 'http://127.0.0.1:54321';

  final ApiMode mode;

  /// Scheme and host, no trailing slash, no `/functions/v1` suffix — the Supabase
  /// client appends the rest.
  final String supabaseUrl;

  /// Sent as the `apikey` header on every request. This is the *publishable* key;
  /// it is not a secret and it is not sufficient on its own, since every route
  /// resolves a real user through `auth.getUser` before it does anything.
  final String anonKey;

  /// Fallback credentials for a stack whose guest path is switched off. Null
  /// unless BOTH are passed — half a credential pair is a configuration mistake,
  /// not a mode. See [SupabaseTransport] for when they are used.
  final String? devEmail;
  final String? devPassword;

  bool get isLive => mode == ApiMode.live;

  /// Builds a config from strings that have already been read, validating as it
  /// goes.
  ///
  /// [fromEnvironment] is this plus five `String.fromEnvironment` reads. Splitting
  /// them apart is not tidiness: compile-time constants cannot be driven from a
  /// test, so without this seam the two checks below — the ones that turn a
  /// confusing 401-on-every-request into a message naming the flag to pass — would
  /// have no coverage whatsoever, and the first time anyone met them would be on
  /// the demo phone.
  factory BackendConfig.parse({
    required String api,
    String url = defaultSupabaseUrl,
    String anonKey = '',
    String devEmail = '',
    String devPassword = '',
  }) {
    final mode = ApiMode.parse(api);
    // Trailing slashes are stripped because the Supabase client appends its own
    // paths; `http://host/` + `/functions/v1` is a double slash that some proxies
    // route differently, and the flag is usually pasted from a browser bar.
    final trimmedUrl = url.replaceAll(RegExp(r'/+$'), '');

    // Both checks fail at construction, on app start, with the flag to pass. That
    // is the point: a missing key or a schemeless URL otherwise surfaces as a 401
    // or a transport error on EVERY request, which reads as an auth bug or a
    // backend outage and sends you debugging the wrong process.
    if (mode == ApiMode.live) {
      if (anonKey.isEmpty) {
        throw StateError(
          'REPRUSH_API=live needs a key: pass '
          '--dart-define=REPRUSH_SUPABASE_ANON_KEY=<key>. Get it from '
          '`npx supabase status` (Publishable), or '
          '`docker exec supabase_edge_runtime_<project> printenv '
          'SUPABASE_ANON_KEY` for the legacy JWT form.',
        );
      }
      if (!trimmedUrl.startsWith('http://') &&
          !trimmedUrl.startsWith('https://')) {
        throw StateError(
          'REPRUSH_SUPABASE_URL="$trimmedUrl" has no scheme. It must start with '
          'http:// or https:// — the local stack is http://, a hosted project '
          'is https://.',
        );
      }
    }

    return BackendConfig(
      mode: mode,
      supabaseUrl: trimmedUrl,
      anonKey: anonKey,
      devEmail: devEmail.isEmpty ? null : devEmail,
      // A password with no email (or the reverse) is a typo, not a mode. Refusing
      // it here means the fallback path never runs on half a credential pair and
      // then reports "sign-in failed" without saying why.
      devPassword: devEmail.isEmpty || devPassword.isEmpty ? null : devPassword,
    );
  }

  /// Reads the dart-defines. Live mode is the default so a normal app build does
  /// not silently present fabricated territory data.
  factory BackendConfig.fromEnvironment() {
    // `String.fromEnvironment` needs a const NAME, so these five reads can be
    // neither looped nor passed through a helper taking the flag as a parameter.
    return BackendConfig.parse(
      api: const String.fromEnvironment('REPRUSH_API', defaultValue: 'live'),
      url: const String.fromEnvironment(
        'REPRUSH_SUPABASE_URL',
        defaultValue: defaultSupabaseUrl,
      ),
      anonKey: const String.fromEnvironment('REPRUSH_SUPABASE_ANON_KEY'),
      devEmail: const String.fromEnvironment('REPRUSH_DEV_EMAIL'),
      devPassword: const String.fromEnvironment('REPRUSH_DEV_PASSWORD'),
    );
  }
}
