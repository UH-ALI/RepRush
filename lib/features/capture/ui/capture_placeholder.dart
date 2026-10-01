/// Shown where the camera will appear before a session starts: what the
/// camera does, how to set the phone up, and the privacy promise.
///
/// Ownership: A.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/shared/widgets/glass_card.dart';

class CapturePlaceholder extends StatelessWidget {
  const CapturePlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.videocam_outlined, color: RepRushTokens.brand),
              const SizedBox(width: RepRushTokens.spaceSm),
              Text('How it works', style: RepRushTokens.sectionTitle),
            ],
          ),
          const SizedBox(height: RepRushTokens.spaceSm),
          const _Step(
            icon: Icons.stay_current_portrait,
            text: 'Prop your phone up so your whole body is in view.',
          ),
          const _Step(
            icon: Icons.accessibility_new,
            text: 'Hold still for a moment while it calibrates.',
          ),
          const _Step(
            icon: Icons.repeat,
            text:
                'Train — every clean rep is counted, and tap Finish when '
                'you are done.',
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: RepRushTokens.spaceXs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.white70),
        const SizedBox(width: RepRushTokens.spaceSm),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
