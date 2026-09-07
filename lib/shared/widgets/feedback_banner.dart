import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';

class FeedbackBanner extends StatelessWidget {
  const FeedbackBanner({super.key, required this.state, required this.text});
  final LiveFeedbackState state;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(color: state.background, borderRadius: BorderRadius.circular(99), border: Border.all(color: state.foreground.withValues(alpha: .5))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(state.icon, color: state.foreground, size: 20),
      const SizedBox(width: 8),
      Flexible(child: Text(text, style: TextStyle(color: state.foreground, fontWeight: FontWeight.w700))),
    ]),
  );
}
