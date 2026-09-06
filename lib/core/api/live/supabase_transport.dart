/// The Supabase binding of [ApiTransport] — Edge Function calls with the caller's
/// auth token attached, and the guest sign-in that gets one.
///
/// Ownership: B.
///
/// This is the only file in `lib/` that imports `supabase_flutter`. Repositories
/// depend on [ApiTransport]; nothing depends on this except `api_providers.dart`,
/// which constructs it. Keeping the SDK behind one file is what makes §state rule 2
/// ("the UI never calls Supabase directly") checkable by grep rather than by review.
library;

import 'package:flutter/widgets.dart';
import 'package:reprush/core/api/backend_config.dart';
import 'package:reprush/core/api/live/api_transport.dart';
import 'package:reprush/models/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseTransport implements ApiTransport {
  SupabaseTransport(this.config);

  final BackendConfig config;

  /// A memoised FUTURE, not a `bool _ready`.
  ///
  /// Two repositories can fire on the same frame — the map tab asking for
  /// territory while the workout tab asks for movements — and a boolean guard lets
  /// both through before either finishes.
  ///
  /// What losing that race actually costs is `_ensureSignedIn` running twice: two
  /// `signInAnonymously` calls, which burns two slots of GoTrue's 30-per-hour
  /// anonymous limit AND leaves the first account's scores on an account the second
  /// request is no longer using. A duplicate `Supabase.initialize` is separately
  /// documented by the SDK as an error ("This must be called only once"), though
  /// 2.17.2 in fact logs and returns the existing instance; depending on that
  /// leniency would mean depending on a path the vendor still calls a bug.
  Future<void>? _ready;

  Future<void> get _ensured => _ready ??= _initialize();

  Future<void> _initialize() async {
    try {
      // Cheap to call after `runApp` and required before any plugin touch. Doing
      // it here rather than in `lib/main.dart` keeps a Track B prerequisite inside
      // a Track B file — `main.dart` is C's, and this needs no cooperation from it.
      WidgetsFlutterBinding.ensureInitialized();
      // `publishableKey` is the current name for the slot `anonKey` used to fill,
      // and the SDK collapses them with `publishableKey ?? anonKey` into one value
      // — so either key FORM is accepted here. That matters for the local stack,
      // where `npx supabase status` prints the new `sb_publishable_…` key while the
      // edge runtime container still carries the 153-char legacy JWT. Both work;
      // `config.anonKey` keeps the older name because that is what this stack's
      // value actually is, and what every error message below tells you to find.
      await Supabase.initialize(
        url: config.supabaseUrl,
        publishableKey: config.anonKey,
      );
      await _ensureSignedIn();
    } catch (_) {
      // Un-memoise a FAILED initialisation so the next call retries it. Without
      // this, one transient blip at startup — the stack still booting, the phone
      // joining wifi a second late — poisons every later request for the life of
      // the process, and the only fix a developer can see is "restart the app".
      // The caller awaiting this future still receives the error.
      _ready = null;
      rethrow;
    }
  }

  /// Every route resolves a real user through `auth.getUser` before it does
  /// anything (`_shared/auth.ts`), so an apikey on its own 401s. This is what turns
  /// "a client that can reach the server" into "a caller the server will answer".
  Future<void> _ensureSignedIn() async {
    final auth = Supabase.instance.client.auth;

    // supabase_flutter persists the session, so a returning athlete — a guest
    // included — reuses the account they already had. That is load-bearing beyond
    // convenience: lifetime score and the 20-per-day session budget both accrue per
    // user, so a fresh anonymous account on every launch would silently reset both
    // AND burn a slot of the 30-per-hour anonymous sign-in rate limit each time.
    if (auth.currentSession != null) return;

    try {
      // The contract's guest path (A1; api-contract.md §Common rules: "every
      // endpoint requires a Supabase auth bearer token; the guest path issues one
      // too"). Nothing to store, and no signup wall between a judge and the demo.
      await auth.signInAnonymously();
      return;
    } on AuthException catch (guest) {
      final email = config.devEmail;
      final password = config.devPassword;
      if (email == null || password == null) {
        // Raised as a contract error, not a raw AuthException, so callers still
        // have one type to catch. The message names both ways out because
        // "sign-in failed" against a local stack is nearly always this one setting,
        // and it is a server setting — nothing the app can fix about itself.
        throw ApiException(
          code: ApiErrorCode.unauthenticated,
          message:
              'This backend refuses guest sign-in: ${guest.message}. Either '
              'enable it — [auth] enable_anonymous_sign_ins = true in '
              'supabase/config.toml, then restart the stack — or build with '
              '--dart-define=REPRUSH_DEV_EMAIL and REPRUSH_DEV_PASSWORD.',
          statusCode: 401,
        );
      }
      await _signInWithPassword(email, password);
    }
  }

  /// Fallback for a stack with the guest path switched off: sign in, registering on
  /// the way past if the account does not exist yet. Local GoTrue auto-confirms, so
  /// `signUp` hands back a usable session immediately; a hosted project with email
  /// confirmation on would not, and the check below says so instead of letting a
  /// tokenless client discover it as a 401 on the first real request.
  Future<void> _signInWithPassword(String email, String password) async {
    final auth = Supabase.instance.client.auth;
    try {
      final result = await auth.signInWithPassword(
        email: email,
        password: password,
      );
      if (result.session != null) return;
    } on AuthException {
      // No such account yet — fall through and create it.
    }
    final created = await auth.signUp(email: email, password: password);
    if (created.session == null) {
      throw const ApiException(
        code: ApiErrorCode.unauthenticated,
        message:
            'Signed up but received no session, which means email confirmation is '
            'enabled on this backend. Confirm the account, or turn confirmation off '
            'for local development.',
        statusCode: 401,
      );
    }
  }

  @override
  Future<Object?> get(String function) =>
      _invoke(function, HttpMethod.get, null);

  @override
  Future<Object?> post(String function, Map<String, Object?> body) =>
      _invoke(function, HttpMethod.post, body);

  Future<Object?> _invoke(
    String function,
    HttpMethod method,
    Object? body,
  ) async {
    await _ensured;
    try {
      // `method` is passed explicitly. `invoke` defaults to POST and does NOT infer
      // GET from a null body, so omitting it would POST to `/movements` — which
      // answers 405 from a route that only reads, and reads like a broken endpoint
      // rather than a wrong verb.
      final response = await Supabase.instance.client.functions.invoke(
        function,
        method: method,
        body: body,
      );
      return response.data;
    } on FunctionException catch (error) {
      throw _asApiException(function, error);
    }
  }

  ApiException _asApiException(String function, FunctionException error) {
    // `status == 0` means no response arrived at all (FunctionsFetchException sets
    // it). That is not a contract error, and feeding it to the envelope parser
    // reports "HTTP 0 with no JSON error envelope" — which sends you looking for a
    // backend bug when the usual truth is an unreachable URL: loopback from an
    // emulator, a phone on the wrong network, or Android refusing cleartext HTTP.
    // Naming the URL puts the likely cause inside the message.
    if (error.status == 0) {
      return ApiException(
        code: ApiErrorCode.internal,
        message:
            'No response from $function at ${config.supabaseUrl}: '
            '${error.details}',
        statusCode: 0,
      );
    }
    // Every route answers 4xx with `{ code, message }`, and `verify_jwt = false` in
    // config.toml exists precisely so the runtime never emits a bare 401 without
    // that envelope. So the details are normally parseable as they stand.
    return ApiException.fromResponse(
      statusCode: error.status,
      body: error.details,
    );
  }
}
