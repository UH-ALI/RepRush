/// [AccountRepository] over Supabase Auth: guest → email account in place, log
/// in, log out.
///
/// Ownership: B.
///
/// SAVING PROGRESS KEEPS THE SAME USER ID. A guest is a real `auth.users` row
/// (anonymous sign-in), so attaching an email to it — rather than signing up a
/// second account — leaves every ledger row, hex and claim where it is. Two
/// `updateUser` calls, email then password, because GoTrue refuses a password on
/// a user that still has no email.
///
/// With "Confirm email" OFF (the local default, and what the demo project
/// needs) the email attaches immediately. With it ON, GoTrue mails a
/// confirmation link instead and the email stays pending; that case is reported
/// in words rather than half-completing silently.
library;

import 'package:reprush/core/api/live/supabase_transport.dart';
import 'package:reprush/core/api/repositories.dart';
import 'package:reprush/models/models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseAccountRepository implements AccountRepository {
  const SupabaseAccountRepository({required this.transport});

  final SupabaseTransport transport;

  GoTrueClient get _auth => Supabase.instance.client.auth;

  AccountState _stateOf(User? user) {
    final email = user?.email;
    return user == null || user.isAnonymous || email == null || email.isEmpty
        ? const AccountState.guest()
        : AccountState.signedIn(email);
  }

  @override
  Future<AccountState> current() async {
    await transport.ready();
    return _stateOf(_auth.currentUser);
  }

  @override
  Future<AccountState> saveProgress({
    required String email,
    required String password,
  }) async {
    await transport.ready();
    final wanted = email.trim().toLowerCase();
    return _guard(() async {
      var user = _auth.currentUser;
      if (user?.email?.toLowerCase() != wanted) {
        user = (await _auth.updateUser(UserAttributes(email: wanted))).user;
        if (user?.email?.toLowerCase() != wanted) {
          throw AccountException(
            'We sent a confirmation link to $wanted. Open it, then come back '
            'and tap Save again.',
          );
        }
      }
      final saved = await _auth.updateUser(UserAttributes(password: password));
      return _stateOf(saved.user);
    });
  }

  @override
  Future<AccountState> logIn({
    required String email,
    required String password,
  }) async {
    await transport.ready();
    return _guard(() async {
      final result = await _auth.signInWithPassword(
        email: email.trim().toLowerCase(),
        password: password,
      );
      return _stateOf(result.user);
    });
  }

  @override
  Future<AccountState> logOut() async {
    await transport.ready();
    return _guard(() async {
      await _auth.signOut();
      // Straight back in as a fresh guest: every route needs a bearer token,
      // and the app has no signed-out screen to fall back to.
      final result = await _auth.signInAnonymously();
      return _stateOf(result.user);
    });
  }

  Future<AccountState> _guard(Future<AccountState> Function() body) async {
    try {
      return await body();
    } on AccountException {
      rethrow;
    } on AuthException catch (error) {
      throw AccountException(_describe(error));
    } on Exception {
      // Socket/HTTP failures from the SDK's client, before any auth response.
      throw const AccountException(
        "Can't reach RepRush right now. Check your connection and try again.",
      );
    }
  }

  static String _describe(AuthException error) => switch (error.code) {
    'invalid_credentials' => "That email and password don't match an account.",
    'email_exists' || 'user_already_exists' =>
      'That email already has an account. Log in instead.',
    'weak_password' => 'Use a password of at least 6 characters.',
    'email_address_invalid' ||
    'validation_failed' => "That doesn't look like an email address.",
    'email_not_confirmed' =>
      'Confirm your email first — check your inbox for the link.',
    'over_email_send_rate_limit' ||
    'over_request_rate_limit' => 'Too many tries. Wait a minute and try again.',
    'anonymous_provider_disabled' =>
      "Guest play is switched off on this server, so you can't log out.",
    _ when error.statusCode == null =>
      "Can't reach RepRush right now. Check your connection and try again.",
    _ => 'Something went wrong. Please try again.',
  };
}
