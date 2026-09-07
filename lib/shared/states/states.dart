/// Shared empty / loading / error states (roles.md C-12 seeds).
///
/// Ownership: C.
library;

import 'package:flutter/material.dart';
import 'package:reprush/app/theme/design_tokens.dart';
import 'package:reprush/models/models.dart';

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(color: RepRushTokens.brand),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inbox_outlined, size: 48, color: RepRushTokens.brand.withValues(alpha: .7)),
            const SizedBox(height: RepRushTokens.spaceSm),
            Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

/// Renders an [ApiException] as a reason, not a failure — D4 must read as a
/// reason (roles.md C-12).
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.error, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final api = error is ApiException ? error as ApiException : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RepRushTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline),
            const SizedBox(height: RepRushTokens.spaceSm),
            Text(
              api?.message ?? 'Something went wrong.',
              textAlign: TextAlign.center,
            ),
            if (api != null) ...[
              const SizedBox(height: RepRushTokens.spaceXs),
              Text(
                'code: ${api.code}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: RepRushTokens.spaceMd),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
