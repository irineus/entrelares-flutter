import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../models/care_schedule.dart';
import '../models/member.dart';
import '../services/custody_data_source.dart';
import '../widgets/app_l10n.dart';
import 'calendar_screen.dart' show slotColors;

/// The day sheet — a native modal bottom sheet (owner directive: use the
/// platform where it improves on the web's inline panel). Read view plus the
/// slice's ONE write path: setting the day's scheduled responsible. The full
/// editor (handoff time, notes, swaps) stays out of the spike on purpose.
///
/// Returns true when a write happened (the caller reloads the month —
/// Realtime also fires, this is just the immediate echo).
Future<bool?> showDaySheet({
  required BuildContext context,
  required DateTime date,
  required CareSchedule? day,
  required CareSchedule? previousDay,
  required List<Member> members,
  required List<MemberView> memberViews,
  required DateTime today,
  required CustodyDataSource dataSource,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _DaySheet(
      date: date,
      day: day,
      previousDay: previousDay,
      members: members,
      memberViews: memberViews,
      today: today,
      dataSource: dataSource,
    ),
  );
}

class _DaySheet extends StatefulWidget {
  final DateTime date;
  final CareSchedule? day;
  final CareSchedule? previousDay;
  final List<Member> members;
  final List<MemberView> memberViews;
  final DateTime today;
  final CustodyDataSource dataSource;

  const _DaySheet({
    required this.date,
    required this.day,
    required this.previousDay,
    required this.members,
    required this.memberViews,
    required this.today,
    required this.dataSource,
  });

  @override
  State<_DaySheet> createState() => _DaySheetState();
}

class _DaySheetState extends State<_DaySheet> {
  int? _selectedParentId;
  bool _saving = false;
  String? _error;

  /// Past days are immutable by business rule — the DB day-protection trigger
  /// enforces it on every write path; this is the client mirror.
  bool get _isPast {
    final d = widget.date;
    final t = widget.today;
    return DateTime(d.year, d.month, d.day)
        .isBefore(DateTime(t.year, t.month, t.day));
  }

  @override
  void initState() {
    super.initState();
    _selectedParentId = widget.day?.scheduledParentId;
  }

  Future<void> _save() async {
    final selected = _selectedParentId;
    if (selected == null || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final existing = widget.day;
      if (existing == null) {
        await widget.dataSource.insertDay(CareSchedule(
          id: 0,
          scheduleDate: widget.date,
          scheduledParentId: selected,
        ));
      } else {
        // Full-row update carrying the T-33/T-35 echo (see CareSchedule).
        await widget.dataSource
            .updateDay(existing.copyWith(scheduledParentId: selected));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final raw = e.toString();
      if (!mounted) return;
      final l = AppL10n.of(context).l;
      setState(() {
        _saving = false;
        _error = isSessionExpired(raw)
            ? sessionExpiredMessage(l)
            : isDayConflict(raw)
                ? l[KApp.errConcurrentSaveRetry]
                : translateSaveError(raw, l[KApp.errDaySave], l);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = widget.day;
    final assignment = day == null
        ? null
        : DayAssignment(
            scheduledParentId: day.scheduledParentId,
            actualParentId: day.actualParentId,
          );
    final previous = widget.previousDay;
    final isTransition = day != null &&
        isTransitionDay(
          previous == null
              ? null
              : (previous.actualParentId ?? previous.scheduledParentId),
          assignment!.effectiveParentId,
        );

    final l = AppL10n.of(context).l;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 8,
          bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${formatHandoffDate(widget.date, l)} · '
              '${daysUntilLabel(widget.date, widget.today, l)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            if (day == null)
              Text(l[KApp.sheetNoResponsible])
            else ...[
              Text(l.format(KApp.sheetResponsible, [
                    displayInitials(
                        assignment!.effectiveParentId, widget.memberViews)
                  ]) +
                  (isSwapped(assignment) ? l[KApp.sheetSwappedSuffix] : '')),
              if (isTransition)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    day.handoffTime != null
                        // U-24: the wire's HH:mm:ss renders per language
                        // (14:30 · 2:30 PM) — never a raw substring.
                        ? l.format(KApp.sheetTransitionAt,
                            [l.formatTimeString(day.handoffTime!)])
                        : l[KApp.sheetTransition],
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if ((day.notes ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(l.format(KApp.sheetNote, [day.notes]),
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
            const SizedBox(height: 16),
            if (_isPast)
              // The web's amber readonly banner (Home.razor .readonly-banner):
              // the only blocked-day state that exists in this lote — frozen
              // and admin-override arrive with lotes 3/2.
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  l[K.editorPastReadonly],
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF92400E)),
                ),
              )
            else ...[
              Text(l[KApp.sheetWhoQuestion],
                  style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in widget.members)
                    ChoiceChip(
                      avatar: CircleAvatar(
                        backgroundColor: slotColors[
                                profileSlotIndex(m.id, widget.memberViews)] ??
                            slotColors[0],
                        child: Text(
                          displayInitials(m.id, widget.memberViews),
                          style: const TextStyle(
                              fontSize: 10, color: Colors.white),
                        ),
                      ),
                      label: Text(m.fullName.split(' ').first),
                      selected: _selectedParentId == m.id,
                      onSelected: (_) =>
                          setState(() => _selectedParentId = m.id),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _selectedParentId == null ||
                        _saving ||
                        _selectedParentId == widget.day?.scheduledParentId
                    ? null
                    : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(l[KApp.sheetSave]),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
