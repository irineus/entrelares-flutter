import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'app_l10n.dart';

/// Today at a Glance — port of `TodayCard.razor`. A dumb presentational
/// widget: every rule arrives computed ([TodayGlance] and the pure helpers in
/// core); the card only renders. The bottom half is a 3-way branch in the
/// web's precedence order: invite nudge (F-31) > today's responsible >
/// no-responsible hint.
class TodayCard extends StatelessWidget {
  final TodayGlance glance;
  final String userFullName;
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
    required this.today,
    required this.nextHandoffDate,
    required this.viewingCurrentMonth,
    required this.showInviteNudge,
    required this.onGoToToday,
    required this.onInvite,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context).l;
    final topColor = context.tokens.slot(glance.userSlot).tone.solid;
    final bottomColor =
        context.tokens.slot(glance.responsibleSlot).tone.solid;

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
                  Text(l.format(K.cardGreeting, [userFullName]),
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
            _AccentStrip(
              color: showInviteNudge || !glance.hasSchedule
                  ? topColor
                  : bottomColor,
              child: showInviteNudge
                  ? _inviteNudge(context, l)
                  : glance.hasSchedule
                      ? _responsibleRow(context, l, bottomColor)
                      : _noResponsibleRow(context, l),
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
          BuildContext context, Localization l, Color bottomColor) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(
            backgroundColor: bottomColor,
            child: Text(glance.avatarLetter,
                style: const TextStyle(color: Colors.white)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l[K.cardResponsibleToday],
                    style: Theme.of(context).textTheme.labelSmall),
                Text(glance.responsibleName ?? l[K.homeNotDefined],
                    style: Theme.of(context).textTheme.titleMedium),
                // Web: both badges can appear — swapped and the ⏰ time are
                // independent.
                if (glance.isSwapped || glance.handoffTime != null)
                  Wrap(
                    spacing: 8,
                    children: [
                      if (glance.isSwapped)
                        Text(l[K.cardSwappedBadge],
                            style: Theme.of(context).textTheme.labelSmall),
                      if (glance.handoffTime != null)
                        Text('⏰ ${l.formatTimeString(glance.handoffTime!)}',
                            style: Theme.of(context).textTheme.labelSmall),
                    ],
                  ),
              ],
            ),
          ),
          if (nextHandoffDate != null) _handoffBlock(context, l),
        ],
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
