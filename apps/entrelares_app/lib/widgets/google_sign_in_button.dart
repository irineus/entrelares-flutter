import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import 'app_l10n.dart';

/// F-57 — "Continuar com Google", shared by the login and register screens.
///
/// It renders NOTHING until [enabled] answers `true`, and [enabled] is
/// GoTrue's own settings endpoint saying the provider exists — the fail-closed
/// switch: while the owner has not configured the provider in a project's
/// console, that project's builds simply have no button, and a network failure
/// looks the same. The password form above it never depends on this answer.
class GoogleSignInButton extends StatelessWidget {
  final Future<bool> enabled;
  final Future<void> Function() onPressed;

  const GoogleSignInButton({
    super.key,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    return FutureBuilder<bool>(
      future: enabled,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        // The spacing rides INSIDE the visible state, so the disabled state
        // collapses to nothing instead of leaving a hole in the layout.
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.account_circle_outlined),
            onPressed: () async {
              try {
                await onPressed();
              } catch (_) {
                // The redirect could not even launch (no browser, platform
                // refusal) — the one failure mode that is OURS to report;
                // everything after the launch belongs to the provider page.
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l[KApp.authGoogleErr])));
                }
              }
            },
            label: Text(l[KApp.authGoogle]),
          ),
        );
      },
    );
  }
}
