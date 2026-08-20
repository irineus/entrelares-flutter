import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'app_l10n.dart';

/// Today at a Glance — port of `TodayCard.razor`. A dumb presentational
/// widget: every rule arrives computed ([TodayGlance] and the pure helpers in
/// core); the card only renders. The bottom half is a 3-way branch in the
/// web's precedence order: invite nudge (F-31) > today's responsible >
/// no-responsible hint.
///
/// U-28 rebuilt the look, not the rules. Three things were wrong:
///
/// * **Colour had been demoted to a 4 px stripe.** The web tints the whole
///   responsible band, which is what makes "who has the child today" readable
///   from across the room; the port left the band neutral with a hairline of
///   colour on its left edge. The band is filled again — `tone.container` with
///   `tone.onContainer` text, so it stays a token decision and stays legible in
///   both themes.
/// * **The role and the handoff time were gone.** "Fernanda Daroit" says less
///   than "Fernanda Daroit · Mãe · 19:00", and the web showed all three.
/// * **The greeting used the full legal name** and wrapped onto three lines on
///   a phone. It greets by FIRST name now; the full name is one tap away in the
///   account menu, and a greeting that wraps is not a greeting.
class TodayCard extends StatelessWidget {
  final TodayGlance glance;
  final String userFullName;

  /// The responsible's role as this reader's language spells it ("Mãe"), or
  /// null when the family has not set one. Resolved by the screen, which is
  /// where the roles are loaded.
  final String? responsibleRole;
  final DateTime today;
  final DateTime? nextHandoffDate;
  final bool viewingCurrentMonth;
  final bool showInviteNudge;
  final VoidCallback onGoToToday;
  final VoidCallback onInvite;

  const TodayCard({
    super.key,
    required this.glance,
    required this.userFullName,
    this.responsibleRole,
    required this.today,
    required this.nextHandoffDate,
    required this.viewingCurrentMonth,
    required this.showInviteNudge,
    required this.onGoToToday,
    required this.onInvite,
  });

  /// The greeting's name. The web prints the full legal name; on a phone that
  /// is three lines of card spent on something the reader already knows.
  String get _firstName {
    final parts = userFullName.trim().split(' ');
    return parts.isEmpty ? userFullName : parts.first;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    final topColor = context.tokens.slot(glance.userSlot).tone.solid;
    final responsible = context.tokens.slot(glance.responsibleSlot);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Web: the card is clickable only when NOT viewing the current month.
        onTap: viewingCurrentMonth ? null : onGoToToday,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AccentStrip(
              color: topColor,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.format(K.cardGreeting, [_firstName]),
                      style: Theme.of(context).textTheme.titleMedium),
                  Text(l.formatTodayHeading(today),
                      style: Theme.of(context).textTheme.bodySmall),
                  if (!viewingCurrentMonth)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(l[K.cardBackToToday],
                          style: Theme.of(context)
                              .textTheme
                              .labelSmall
                              ?.copyWith(
                                  color:
                                      Theme.of(context).colorScheme.primary)),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (showInviteNudge || !glance.hasSchedule)
              _AccentStrip(
                color: topColor,
                child: showInviteNudge
                    ? _inviteNudge(context, l)
                    : _noResponsibleRow(context, l),
              )
            else
              // U-28: the whole band takes the carer's colour. This is the one
              // place in the app where a reader answers "who has the child
              // today" without reading a word.
              Container(
                color: responsible.tone.container,
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: _responsibleRow(context, l, responsible),
              ),
          ],
        ),
      ),
    );
  }

  Widget _inviteNudge(BuildContext context, Localization l) => Row(
        children: [
          const Text('👋', style: TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l[K.cardInviteTitle],
                    style: Theme.of(context).textTheme.titleSmall),
                Text(l[K.cardInviteHint],
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
              onPressed: onInvite, child: Text(l[K.cardInviteAction])),
        ],
      );

  Widget _responsibleRow(
      BuildContext context, Localization l, SlotColors responsible) {
    final textTheme = Theme.of(context).textTheme;
    final on = responsible.tone.onContainer;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        CircleAvatar(
          backgroundColor: responsible.tone.solid,
          child: Text(glance.avatarLetter,
              style: TextStyle(color: responsible.tone.onSolid)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l[K.cardResponsibleToday],
                  style: textTheme.labelSmall?.copyWith(color: on)),
              Text(glance.responsibleName ?? l[K.homeNotDefined],
                  style: textTheme.titleMedium?.copyWith(color: on),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              // Web: both badges can appear — swapped and the ⏰ time are
              // independent. U-28 adds the ROLE, which the port had dropped.
              if (responsibleRole != null ||
                  glance.isSwapped ||
                  glance.handoffTime != null)
                Padding(
                  padding: const EdgeInsets.only(top: Spacing.xs),
                  child: Wrap(
                    spacing: Spacing.sm,
                    runSpacing: Spacing.xs,
                    children: [
                      if (responsibleRole != null)
                        _pill(context, responsibleRole!, responsible),
                      if (glance.isSwapped)
                        _pill(context, l[K.cardSwappedBadge],
                            context.tokens.swapped),
                      if (glance.handoffTime != null)
                        _pill(
                            context,
                            '⏰ ${l.formatTimeString(glance.handoffTime!)}',
                            responsible),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (nextHandoffDate != null) _handoffBlock(context, l),
      ],
    );
  }

  /// A pill ON the tinted band. It cannot be [AppBadge]: that one paints the
  /// tone's own container, which here would be the same colour as the band it
  /// sits on. This one uses the solid at low opacity, so it reads as raised out
  /// of the band rather than as a hole in it.
  Widget _pill(BuildContext context, String text, SlotColors slot) => Container(
        padding: const EdgeInsets.symmetric(
            horizontal: Spacing.sm, vertical: Spacing.xs / 2),
        decoration: BoxDecoration(
          color: slot.tone.solid.withValues(alpha: 0.14),
          border: Border.all(color: slot.tone.border),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: slot.tone.onContainer)),
      );

  Widget _noResponsibleRow(BuildContext context, Localization l) => Row(
        children: [
          const Text('📭', style: TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l[K.cardNoResponsibleTitle],
                    style: Theme.of(context).textTheme.titleSmall),
                Text(l[K.cardNoResponsibleHint],
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          // Parity: the web repeats the handoff block in this branch too (in
          // practice Home nulls the date on no-schedule days — kept identical).
          if (nextHandoffDate != null) _handoffBlock(context, l),
        ],
      );

  Widget _handoffBlock(BuildContext context, Localization l) {
    final date = nextHandoffDate!;
    final urgencyColor = switch (handoffUrgency(date, today)) {
      HandoffUrgency.urgent => Theme.of(context).colorScheme.error,
      HandoffUrgency.soon => context.tokens.warning.onContainer,
      HandoffUrgency.near => context.tokens.warning.solid,
      HandoffUrgency.none => Theme.of(context).hintColor,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(l[K.cardNextHandoff],
            style: Theme.of(context).textTheme.labelSmall),
        Text(formatHandoffDate(date, l),
            style: Theme.of(context).textTheme.bodyMedium),
        Text(daysUntilLabel(date, today, l),
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: urgencyColor, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

class _AccentStrip extends StatelessWidget {
  final Color color;
  final Widget child;

  const _AccentStrip({required this.color, required this.child});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: color, width: 4)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: child,
      );
}
