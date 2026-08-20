/// U-27 — the components that carry STRUCTURE: what a section looks like, what
/// a card looks like, what a label/value row looks like, how a sheet opens.
///
/// None of these invents a look. They fix the one the app already had in six
/// slightly different versions — `_sectionTitle` in Família, the same title
/// with different padding in Relatórios, `_infoRow` in Notificações against a
/// hand-built `Row` in the day sheet.
library;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// A section's title, with an optional action on the right (the "editar" of a
/// panel, the "ver tudo" of a list).
class AppSectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  /// Spacing above. Zero for the first section on a screen, which already has
  /// the app bar above it.
  final double topSpacing;

  const AppSectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.topSpacing = Spacing.lg,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: topSpacing, bottom: Spacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleMedium),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A bordered surface with the app's padding. The colour, the border and the
/// radius come from `CardTheme`; what this adds is the padding every screen was
/// re-deciding, and an optional header so a titled card is one widget.
class AppCard extends StatelessWidget {
  final Widget child;
  final String? title;
  final Widget? titleTrailing;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  const AppCard({
    super.key,
    required this.child,
    this.title,
    this.titleTrailing,
    this.padding = const EdgeInsets.all(Spacing.md),
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: padding,
      child: title == null
          ? child
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppSectionHeader(
                    title: title!,
                    trailing: titleTrailing,
                    topSpacing: 0),
                child,
              ],
            ),
    );
    return Card(
      child: onTap == null
          ? content
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(Radii.md),
              child: content,
            ),
    );
  }
}

/// A label on the left, its value on the right — the shape of every detail
/// panel in the app (a swap's dates, a subscription's next charge).
class AppListRow extends StatelessWidget {
  final String label;

  /// The value as text. Mutually exclusive with [valueWidget].
  final String? value;
  final Widget? valueWidget;

  /// How much wider the value column is than the label's. The app's panels all
  /// settled on 2:1, which is why it is the default rather than a parameter
  /// every call site has to think about.
  final int valueFlex;

  const AppListRow({
    super.key,
    required this.label,
    this.value,
    this.valueWidget,
    this.valueFlex = 2,
  }) : assert(value != null || valueWidget != null,
            'A row with no value is a section header, not a row.');

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.xs / 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child:
                Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            flex: valueFlex,
            child: valueWidget ??
                Text(value!, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

/// The title block of a bottom sheet. The drag handle itself is the theme's
/// (`showDragHandle: true` plus `bottomSheetTheme`) — this is what goes under
/// it, so every sheet in the app starts the same way.
class AppSheetHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;

  const AppSheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: textTheme.titleLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: Spacing.xs),
                  Text(subtitle!, style: textTheme.bodySmall),
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
