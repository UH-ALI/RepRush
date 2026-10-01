/// Name and account flows opened from the Profile tab: pick your name, save a
/// guest's progress to an email, log in, log out.
///
/// Every athlete starts as a guest with a generated handle (`athlete_3f9a2c`)
/// so nobody hits a signup wall; these sheets are how they become someone.
///
/// Ownership: C (ui).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/core/api/api_providers.dart';
import 'package:reprush/features/challenges/data/challenges_providers.dart';
import 'package:reprush/features/progression/data/progression_providers.dart';
import 'package:reprush/features/session/data/session_providers.dart';
import 'package:reprush/features/territory/data/territory_providers.dart';
import 'package:reprush/shared/errors.dart';
import 'package:reprush/shared/widgets/widgets.dart';

/// True for the handle a guest is given at signup (`handle_new_user()` in
/// `0001_core.sql`) — i.e. the athlete hasn't picked a name yet.
bool isGeneratedHandle(String handle) =>
    RegExp(r'^athlete_[0-9a-f]{6}$').hasMatch(handle);

/// Reloads everything that shows who you are. [switchedAccount] also drops
/// per-user state that belonged to the previous account.
void refreshIdentity(WidgetRef ref, {bool switchedAccount = false}) {
  ref
    ..invalidate(profileProvider)
    ..invalidate(leaderboardProvider)
    ..invalidate(hexesProvider)
    ..invalidate(hexDetailProvider);
  if (switchedAccount) {
    if (ref.read(activeSessionProvider) != null) {
      ref.read(activeSessionProvider.notifier).abandon();
    }
    ref
      ..invalidate(accountProvider)
      ..invalidate(movementsProvider)
      ..invalidate(dailyChallengeProvider);
  }
}

Future<void> showRenameSheet(BuildContext context, {required String current}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: RepRushTokens.surfaceDark,
    isScrollControlled: true,
    builder: (_) => _RenameSheet(current: current),
  );
}

enum AccountSheetMode { saveProgress, logIn }

Future<void> showAccountSheet(BuildContext context, AccountSheetMode mode) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: RepRushTokens.surfaceDark,
    isScrollControlled: true,
    builder: (_) => _AccountSheet(mode: mode),
  );
}

Future<void> confirmLogOut(BuildContext context, WidgetRef ref) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Log out?'),
      content: const Text(
        "You'll keep playing as a new guest. Log back in any time to get "
        'your progress back.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Log out'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  try {
    await ref.read(accountRepositoryProvider).logOut();
    refreshIdentity(ref, switchedAccount: true);
  } on Object catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }
}

// ---------------------------------------------------------------------------

/// Shared frame: title, subtitle, fields, error line, one primary button.
/// Lifts above the keyboard.
class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.subtitle,
    required this.fields,
    required this.error,
    required this.action,
  });

  final String title;
  final String subtitle;
  final List<Widget> fields;
  final String? error;
  final Widget action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: RepRushTokens.sectionTitle),
            const SizedBox(height: RepRushTokens.spaceXs),
            Text(subtitle, style: RepRushTokens.bodyLabel),
            const SizedBox(height: RepRushTokens.spaceMd),
            ...fields,
            if (error != null) ...[
              const SizedBox(height: RepRushTokens.spaceSm),
              Text(error!, style: const TextStyle(color: Color(0xFFFF8A80))),
            ],
            const SizedBox(height: RepRushTokens.spaceMd),
            action,
          ],
        ),
      ),
    ),
  );
}

InputDecoration _field(String label, IconData icon) => InputDecoration(
  labelText: label,
  prefixIcon: Icon(icon),
  filled: true,
  fillColor: Colors.white.withValues(alpha: .06),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(RepRushTokens.cornerChip),
    borderSide: BorderSide.none,
  ),
  counterText: '',
);

class _RenameSheet extends ConsumerStatefulWidget {
  const _RenameSheet({required this.current});

  final String current;

  @override
  ConsumerState<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends ConsumerState<_RenameSheet> {
  late final _name = TextEditingController(
    text: isGeneratedHandle(widget.current) ? '' : widget.current,
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(progressionRepositoryProvider).rename(_name.text);
      refreshIdentity(ref);
      if (mounted) Navigator.pop(context);
    } on Object catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: 'Pick your name',
    subtitle: 'Rivals see it on the leaderboard and on every hex you hold.',
    fields: [
      TextField(
        controller: _name,
        autofocus: true,
        maxLength: 20,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        decoration: _field('Name', Icons.person_outline),
      ),
    ],
    error: _error,
    action: BrandButton(
      label: 'Save name',
      icon: Icons.check,
      loading: _saving,
      onPressed: _save,
    ),
  );
}

class _AccountSheet extends ConsumerStatefulWidget {
  const _AccountSheet({required this.mode});

  final AccountSheetMode mode;

  @override
  ConsumerState<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<_AccountSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  bool get _saving => widget.mode == AccountSheetMode.saveProgress;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final email = _email.text.trim();
    final password = _password.text;
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = "That doesn't look like an email address.");
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Use a password of at least 6 characters.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = ref.read(accountRepositoryProvider);
    try {
      if (_saving) {
        await account.saveProgress(email: email, password: password);
        // Same user id, so only the account line changes.
        ref.invalidate(accountProvider);
      } else {
        await account.logIn(email: email, password: password);
        refreshIdentity(ref, switchedAccount: true);
      }
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            _saving ? 'Progress saved to $email.' : 'Welcome back!',
          ),
        ),
      );
    } on Object catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
    title: _saving ? 'Save your progress' : 'Log in',
    subtitle: _saving
        ? 'Add an email and password to keep your score, level and territory '
              'if you change phones.'
        : "Switch this phone to your account. This guest's progress stays "
              'behind.',
    fields: [
      TextField(
        controller: _email,
        autofocus: true,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const [AutofillHints.email],
        textInputAction: TextInputAction.next,
        decoration: _field('Email', Icons.mail_outline),
      ),
      const SizedBox(height: RepRushTokens.spaceSm),
      TextField(
        controller: _password,
        obscureText: true,
        autofillHints: [
          _saving ? AutofillHints.newPassword : AutofillHints.password,
        ],
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: _field('Password', Icons.lock_outline),
      ),
    ],
    error: _error,
    action: BrandButton(
      label: _saving ? 'Save progress' : 'Log in',
      icon: _saving ? Icons.cloud_done_outlined : Icons.login,
      loading: _busy,
      onPressed: _submit,
    ),
  );
}
