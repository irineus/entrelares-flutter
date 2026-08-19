import 'package:entrelares_core/entrelares_core.dart';
import 'package:flutter/material.dart';

import '../models/care_schedule.dart';
import '../models/member.dart';
import '../services/custody_data_source.dart';
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
      setState(() {
        _saving = false;
        _error = isSessionExpired(raw)
            ? sessionExpiredMessage
            : isDayConflict(raw)
                ? 'Outro responsável salvou este dia primeiro — atualize o '
                    'calendário e tente novamente.'
                : translateSaveError(raw, 'Não foi possível salvar o dia.');
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
              '${formatHandoffDate(widget.date)} · '
              '${daysUntilLabel(widget.date, widget.today)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            if (day == null)
              const Text('Dia sem responsável definido.')
            else ...[
              Text(
                  'Responsável: ${displayInitials(assignment!.effectiveParentId, widget.memberViews)}'
                  '${isSwapped(assignment) ? ' (trocado)' : ''}'),
              if (isTransition)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    day.handoffTime != null
                        ? 'Dia de transição — troca às ${day.handoffTime!.substring(0, 5)}'
                        : 'Dia de transição',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if ((day.notes ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Observação: ${day.notes}',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
            const SizedBox(height: 16),
            if (_isPast)
              Text('Dias passados são imutáveis.',
                  style: Theme.of(context).textTheme.bodySmall)
            else ...[
              Text('Quem fica com a criança neste dia?',
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
                    : const Text('Salvar'),
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
