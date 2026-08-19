import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

/// The web's three toast types (`ToastService`), same visual language.
enum AppSnackType { success, error, info }

/// The Flutter face of the web's toast: one at a time (a new call replaces the
/// current one, as `ToastService.Show` overwrites), duration scaling with the
/// reading load ([snackDismissDelayMs]), and tappable to dismiss — a user who
/// already read a long summary doesn't have to wait it out.
///
/// [message] must come from the catalog (`l[K.x]`), never a literal — the
/// `no_literal_snack_test` gate scans call sites, as the web's
/// `NoToast_CarriesALiteralString` does.
void showAppSnack(BuildContext context, String message,
    {AppSnackType type = AppSnackType.success}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();

  // The web palette (MainLayout.razor.css .toast-*), verbatim.
  final (background, foreground, border, icon) = switch (type) {
    AppSnackType.success => (
        const Color(0xFFECFDF5),
        const Color(0xFF065F46),
        const Color(0xFF6EE7B7),
        '✅'
      ),
    AppSnackType.error => (
        const Color(0xFFFEF2F2),
        const Color(0xFF991B1B),
        const Color(0xFFFCA5A5),
        '❌'
      ),
    AppSnackType.info => (
        const Color(0xFFEFF6FF),
        const Color(0xFF1E40AF),
        const Color(0xFF93C5FD),
        'ℹ️'
      ),
  };

  messenger.showSnackBar(SnackBar(
    duration: Duration(milliseconds: snackDismissDelayMs(message.length)),
    behavior: SnackBarBehavior.floating,
    backgroundColor: background,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: BorderSide(color: border),
    ),
    content: GestureDetector(
      onTap: messenger.hideCurrentSnackBar,
      // QA (July 2026, inherited): the message never truncates — it wraps,
      // and the timer scales instead.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                  color: foreground,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  height: 1.45),
            ),
          ),
        ],
      ),
    ),
  ));
}
