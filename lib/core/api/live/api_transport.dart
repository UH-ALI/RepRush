/// The seam between the live repositories and Supabase.
///
/// Ownership: B.
///
/// WHY AN INTERFACE, RATHER THAN CALLING `Supabase.instance` FROM THE REPOSITORIES
/// A repository's whole job is turning a wire shape into a typed model and a
/// non-2xx into an [ApiException]. Neither half can be tested against a real stack
/// in `flutter test` — there is no stack there. One method-shaped hole in between
/// lets a test hand back the exact bytes a route emitted and assert on the model,
/// which is the half that actually breaks. The payloads in
/// `test/live_repositories_test.dart` were captured off the wire rather than typed
/// out from the docs, and that is only possible because of this seam.
///
/// It is also what makes the stub/live switch a per-endpoint decision instead of a
/// whole-app one: a repository depending on [ApiTransport] cannot tell whether its
/// bytes came from Supabase or from a map literal.
library;

import 'package:reprush/models/models.dart';

/// One Edge Function call.
///
/// Implementations throw [ApiException] on any non-2xx — never a
/// transport-specific exception — so callers have exactly one error type to catch,
/// the same one the stubs throw.
abstract interface class ApiTransport {
  /// `GET /functions/v1/[function]`, returning the decoded JSON body.
  Future<Object?> get(String function);

  /// `GET /functions/v1/[function]?k=v…` — [get] with a query string.
  ///
  /// A separate method rather than callers embedding `?k=v` in [function]: the
  /// values need percent-encoding (a bbox carries commas) and the SDK's
  /// `functions.invoke` takes a typed `queryParameters` map that does it, whereas a
  /// hand-built suffix would be re-encoded or dropped depending on the SDK version.
  /// Keys and values are strings because that is all a query string carries.
  Future<Object?> getQuery(String function, Map<String, String> query);

  /// `POST /functions/v1/[function]` with [body] as JSON.
  Future<Object?> post(String function, Map<String, Object?> body);
}
