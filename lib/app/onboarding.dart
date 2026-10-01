/// First-run intro: what the game is, the privacy promise, and a heads-up
/// before the location prompt. Shown once, before the shell — the map (which
/// asks for location) is not built until the athlete taps through, so the OS
/// prompt arrives after the explanation rather than on top of a cold start.
///
/// Ownership: C.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/shared/widgets/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingController extends AsyncNotifier<bool> {
  static const prefsKey = 'onboarding.seen.v1';

  @override
  Future<bool> build() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefsKey) ?? false;
  }

  Future<void> complete() async {
    state = const AsyncData(true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefsKey, true);
  }
}

/// True once the intro has been seen on this device.
final onboardingSeenProvider =
    AsyncNotifierProvider<OnboardingController, bool>(OnboardingController.new);

class OnboardingScreen extends ConsumerWidget {
  const OnboardingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        // Fills the screen when it fits (the Spacers centre the content) and
        // scrolls on short phones or with large accessibility text.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(child: _content(context, ref)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: RepRushTokens.spaceLg),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        const Center(child: HexMark(size: 96)),
        const SizedBox(height: RepRushTokens.spaceMd),
        Text(
          'RepRush',
          textAlign: TextAlign.center,
          style: RepRushTokens.displayLarge.copyWith(fontSize: 52),
        ),
        Text(
          'Train anywhere. Claim your ground.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: RepRushTokens.spaceXl),
        const _Point(
          icon: Icons.hexagon,
          title: 'The map is yours to take',
          body:
              'The world is split into hexes. Train inside one to '
              'claim it.',
        ),
        const _Point(
          icon: Icons.lock_outline,
          title: 'Your camera counts every rep',
          body: 'Counting happens on your phone. Video never leaves it.',
        ),
        const _Point(
          icon: Icons.shield,
          title: 'Hold your ground',
          body:
              'Rivals can take hexes back, and power fades over 72 '
              'hours. Keep training.',
        ),
        const Spacer(flex: 2),
        BrandButton(
          label: "Let's go",
          icon: Icons.arrow_forward,
          onPressed: () => ref.read(onboardingSeenProvider.notifier).complete(),
        ),
        const SizedBox(height: RepRushTokens.spaceSm),
        Text(
          "Next we'll ask for your location so we know which hex "
          "you're in.",
          textAlign: TextAlign.center,
          style: RepRushTokens.bodyLabel,
        ),
        const SizedBox(height: RepRushTokens.spaceMd),
      ],
    ),
  );
}

class _Point extends StatelessWidget {
  const _Point({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: RepRushTokens.spaceMd),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: RepRushTokens.brand.withValues(alpha: .12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Icon(icon, color: RepRushTokens.brand),
          ),
        ),
        const SizedBox(width: RepRushTokens.spaceSm + 4),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(body, style: RepRushTokens.bodyLabel),
            ],
          ),
        ),
      ],
    ),
  );
}

/// The RepRush mark — the launcher icon's gradient hexagon and chevrons,
/// drawn as vectors (see `tool/gen_app_icon.py` for the same geometry).
class HexMark extends StatelessWidget {
  const HexMark({super.key, this.size = 64});

  final double size;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _HexMarkPainter());
}

class _HexMarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final hex = Path();
    for (var i = 0; i < 6; i++) {
      final a = (90 + 60 * i) * math.pi / 180;
      final p = Offset(c.dx + r * math.cos(a), c.dy - r * math.sin(a));
      i == 0 ? hex.moveTo(p.dx, p.dy) : hex.lineTo(p.dx, p.dy);
    }
    hex.close();
    canvas.drawPath(
      hex,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [RepRushTokens.brand, RepRushTokens.electricViolet],
        ).createShader(Offset.zero & size),
    );

    final ink = Paint()..color = RepRushTokens.surfaceDark;
    final w = r * .95, h = r * .42, t = r * .17;
    for (final dy in [-r * .22, r * .26]) {
      final cy = c.dy + dy;
      canvas.drawPath(
        Path()
          ..moveTo(c.dx, cy - h / 2)
          ..lineTo(c.dx + w / 2, cy + h / 2 - t)
          ..lineTo(c.dx + w / 2, cy + h / 2)
          ..lineTo(c.dx, cy - h / 2 + t * 1.15)
          ..lineTo(c.dx - w / 2, cy + h / 2)
          ..lineTo(c.dx - w / 2, cy + h / 2 - t)
          ..close(),
        ink,
      );
    }
  }

  @override
  bool shouldRepaint(_HexMarkPainter oldDelegate) => false;
}
