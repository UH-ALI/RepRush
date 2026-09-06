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

  /// `POST /functions/v1/[function]` with [body] as JSON.
  Future<Object?> post(String function, Map<String, Object?> body);
}
