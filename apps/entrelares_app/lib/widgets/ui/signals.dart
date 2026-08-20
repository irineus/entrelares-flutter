/// U-27 — the components that carry STATE: a banner, a badge, an empty state.
///
/// Each of these existed three or four times over, copied between screens with
/// small drifts: the audit tab's error banner and the summary tab's were the
/// same widget with different padding, and three screens had their own empty
/// state that differed only in whether the body text was centred. The drift is
/// the argument — one implementation cannot drift from itself.
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// A tone-coloured block that says something about the whole screen or the
/// whole form: an admin override in effect, a read that failed, a warning about
/// what the next tap will do.
class AppBanner extends StatelessWidget {
  /// The tone decides the colour AND the meaning — pass `context.tokens.danger`
  /// for something that went wrong, `warning` for something about to.
  final ToneColors tone;
  final String message;
  final String? title;

  /// Rendered before the text. The app writes these as emoji, not icons, and
  /// they travel in the string on purpose (the catalog owns the wording).
  final String? leading;

  /// Whether the banner draws its border. Off inside an already-bordered card.
  final bool bordered;

  const AppBanner({
    super.key,
    required this.tone,
    required this.message,
    this.title,
    this.leading,
    this.bordered = true,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Spacing.sm + Spacing.xs),
      decoration: BoxDecoration(
        color: tone.container,
        border: bordered ? Border.all(color: tone.border) : null,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Text(
              leading == null ? title! : '$leading $title',
              style: textTheme.titleSmall?.copyWith(color: tone.onContainer),
            ),
          if (title != null) const SizedBox(height: Spacing.xs),
          Text(
            title == null && leading != null ? '$leading $message' : message,
            style: textTheme.bodyMedium?.copyWith(color: tone.onContainer),
          ),
        ],
      ),
    );
  }
}

/// A pill: one short word about ONE row — pending, urgent, automatic, created.
class AppBadge extends StatelessWidget {
  final String text;
  final ToneColors tone;

  /// The reader-facing label when the pill's own text is an abbreviation. The
  /// app already leans on this in the notification list, where "Atrasado" is
  /// the pill and the full state is what a screen reader should hear.
  final String? semantics;

  /// `false` paints the solid instead of the container — for a badge that has
  /// to win against a busy row.
  final bool soft;

  const AppBadge({
    super.key,
    required this.text,
    required this.tone,
    this.semantics,
    this.soft = true,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semantics,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm, vertical: Spacing.xs / 2),
        decoration: BoxDecoration(
          color: soft ? tone.container : tone.solid,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Text(
          text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: soft ? tone.onContainer : tone.onSolid,
              ),
        ),
      ),
    );
  }
}

/// Nothing to show, said properly: what is empty, and — when there is one — the
/// reason it is empty. Three screens had their own copy of this.
class AppEmptyState extends StatelessWidget {
  /// The app's convention is an emoji, sized up.
  final String icon;
  final String title;
  final String? body;

  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xl),
      child: Column(
        children: [
          Text(icon, style: const TextStyle(fontSize: 40)),
          const SizedBox(height: Spacing.sm),
          Text(title,
              textAlign: TextAlign.center, style: textTheme.titleMedium),
          if (body != null) ...[
            const SizedBox(height: Spacing.xs),
            Text(body!,
                textAlign: TextAlign.center, style: textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}
