/// Port of `SwapRequestServiceLogicTests.cs` — the pure workflow rules and
/// the F-20/F-22 priority-tag formula (the single urgency source shared, by
/// mirror, with the `send-swap-email` Edge Function) — plus the resolve
/// subsets inline in `Home.razor` that never had a C# unit suite.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

final _day = DateTime(2026, 7, 20);
const _noon = '12:00';
final _today = DateTime(2026, 8, 19);
final _future = DateTime(2026, 8, 22);

void main() {
  group('computePriorityTag — formula boundaries (F-20/F-22)', () {
    // handoff = schedule_date + (handoff_time ?? 00:00)
    // reference >= handoff        → overdue
    // handoff − reference < 24h   → urgent
    // otherwise                   → none

    test('far future and far past classify by the formula (T-32 boundary)',
        () {
      final reference = DateTime(2026, 7, 20, 12);
      expect(computePriorityTag(DateTime(2075, 1, 1), _noon, reference),
          SwapPriorityTag.none);
      expect(computePriorityTag(DateTime(1990, 1, 1), _noon, reference),
          SwapPriorityTag.overdue);
      // Extreme calendar values — no exception.
      expect(computePriorityTag(DateTime(9999, 12, 31), _noon, reference),
          SwapPriorityTag.none);
      expect(computePriorityTag(DateTime(1, 1, 1), _noon, reference),
          SwapPriorityTag.overdue);
    });

    test('more than 24h before is none', () {
      final reference = DateTime(2026, 7, 20, 12).subtract(
          const Duration(hours: 30));
      expect(
          computePriorityTag(_day, _noon, reference), SwapPriorityTag.none);
    });

    test('exactly 24h before is none — the urgent window is STRICTLY under',
        () {
      final reference =
          DateTime(2026, 7, 20, 12).subtract(const Duration(hours: 24));
      expect(
          computePriorityTag(_day, _noon, reference), SwapPriorityTag.none);
    });

    test('just under 24h before is urgent', () {
      final reference = DateTime(2026, 7, 20, 12)
          .subtract(const Duration(hours: 24) - const Duration(minutes: 1));
      expect(
          computePriorityTag(_day, _noon, reference), SwapPriorityTag.urgent);
    });

    test('at the handoff instant is overdue', () {
      expect(computePriorityTag(_day, _noon, DateTime(2026, 7, 20, 12)),
          SwapPriorityTag.overdue);
    });

    test('after the handoff is overdue', () {
      expect(computePriorityTag(_day, _noon, DateTime(2026, 7, 22, 12)),
          SwapPriorityTag.overdue);
    });

    test('null handoff time falls back to midnight (F-22)', () {
      final justBeforeMidnight = DateTime(2026, 7, 19, 23);
      final justAfterMidnight = DateTime(2026, 7, 20, 1);
      expect(computePriorityTag(_day, null, justBeforeMidnight),
          SwapPriorityTag.urgent);
      expect(computePriorityTag(_day, null, justAfterMidnight),
          SwapPriorityTag.overdue);
    });

    test('the "HH:mm:ss" wire form parses like "HH:mm"', () {
      expect(computePriorityTag(_day, '12:00:00', DateTime(2026, 7, 20, 12)),
          SwapPriorityTag.overdue);
    });

    test('unparseable handoff time falls back to midnight', () {
      expect(computePriorityTag(_day, 'not-a-time', DateTime(2026, 7, 20, 1)),
          SwapPriorityTag.overdue);
    });

    test('a resolved request freezes at resolved_at (history semantics)', () {
      // Measured against resolved_at, not the clock — no stored column (F-20).
      final resolvedLocal = DateTime(2026, 7, 20, 10); // urgent window
      expect(
          swapRequestPriorityTag(
            scheduleDate: _day,
            proposedHandoffTime: _noon,
            resolvedAtLocal: resolvedLocal,
            now: DateTime(2030, 1, 1),
          ),
          SwapPriorityTag.urgent);
    });

    test('a pending request is measured against the clock', () {
      expect(
          swapRequestPriorityTag(
            scheduleDate: _day,
            proposedHandoffTime: _noon,
            resolvedAtLocal: null,
            now: DateTime(2026, 7, 20, 13),
          ),
          SwapPriorityTag.overdue);
    });
  });

  group('priorityTagPrefix', () {
    test('maps the tag to the stored notification prefix', () {
      expect(priorityTagPrefix(SwapPriorityTag.none), '');
      expect(priorityTagPrefix(SwapPriorityTag.urgent), '⚠️ URGENTE: ');
      expect(priorityTagPrefix(SwapPriorityTag.overdue), '⏰ ATRASADO: ');
    });
  });

  group('priorityTagParam', () {
    test('urgent/overdue ride params; none is dropped as null', () {
      expect(priorityTagParam(SwapPriorityTag.urgent), 'urgent');
      expect(priorityTagParam(SwapPriorityTag.overdue), 'overdue');
      expect(priorityTagParam(SwapPriorityTag.none), isNull);
    });
  });

  group('shouldTriggerWorkflow', () {
    // Decides when saving a day must create a swap request instead of a
    // direct write.

    test('proposing the other parent on a future day triggers (scenario A)',
        () {
      expect(
          shouldTriggerWorkflow(
              scheduleDate: _future,
              currentActualParentId: null,
              scheduledParentId: 1,
              proposedActualParentId: 2,
              today: _today),
          isTrue);
    });

    test('a past day never triggers', () {
      expect(
          shouldTriggerWorkflow(
              scheduleDate: DateTime(2026, 8, 18),
              currentActualParentId: null,
              scheduledParentId: 1,
              proposedActualParentId: 2,
              today: _today),
          isFalse);
    });

    test('today is allowed — only PAST days are blocked', () {
      expect(
          shouldTriggerWorkflow(
              scheduleDate: _today,
              currentActualParentId: null,
              scheduledParentId: 1,
              proposedActualParentId: 2,
              today: _today),
          isTrue);
    });

    test('proposed equals scheduled does not trigger', () {
      expect(
          shouldTriggerWorkflow(
              scheduleDate: _future,
              currentActualParentId: null,
              scheduledParentId: 1,
              proposedActualParentId: 1,
              today: _today),
          isFalse);
    });

    test('proposed equals current actual does not trigger — re-saving the '
        'already-approved swap state is not a new request', () {
      expect(
          shouldTriggerWorkflow(
              scheduleDate: _future,
              currentActualParentId: 2,
              scheduledParentId: 1,
              proposedActualParentId: 2,
              today: _today),
          isFalse);
    });

    test('no proposed parent (the 0 sentinel) does not trigger', () {
      expect(
          shouldTriggerWorkflow(
              scheduleDate: _future,
              currentActualParentId: null,
              scheduledParentId: 1,
              proposedActualParentId: 0,
              today: _today),
          isFalse);
    });
  });

  group('shouldRequestRevert', () {
    // Decides when clearing/restoring a swapped day must open a revert
    // request.

    test('clearing an approved swap on a future day triggers', () {
      expect(
          shouldRequestRevert(
              scheduleDate: _future,
              currentActualParentId: 2,
              newActualParentId: null,
              scheduledParentId: 1,
              today: _today),
          isTrue);
    });

    test('setting back to the scheduled parent triggers', () {
      expect(
          shouldRequestRevert(
              scheduleDate: _future,
              currentActualParentId: 2,
              newActualParentId: 1,
              scheduledParentId: 1,
              today: _today),
          isTrue);
    });

    test('no active swap does not trigger', () {
      expect(
          shouldRequestRevert(
              scheduleDate: _future,
              currentActualParentId: null,
              newActualParentId: null,
              scheduledParentId: 1,
              today: _today),
          isFalse);
    });

    test('actual already equals scheduled does not trigger', () {
      expect(
          shouldRequestRevert(
              scheduleDate: _future,
              currentActualParentId: 1,
              newActualParentId: null,
              scheduledParentId: 1,
              today: _today),
          isFalse);
    });

    test('a past day never triggers', () {
      expect(
          shouldRequestRevert(
              scheduleDate: DateTime(2026, 8, 18),
              currentActualParentId: 2,
              newActualParentId: null,
              scheduledParentId: 1,
              today: _today),
          isFalse);
    });

    test('keeping the swapped parent does not trigger — nothing is undone',
        () {
      expect(
          shouldRequestRevert(
              scheduleDate: _future,
              currentActualParentId: 2,
              newActualParentId: 2,
              scheduledParentId: 1,
              today: _today),
          isFalse);
    });
  });

  group('requesterParticipates (F-28 scenario-C gate)', () {
    test('scenario A: the planned responsible proposes someone else', () {
      expect(
          requesterParticipates(
              requesterId: 1, scheduledParentId: 1, proposedActualParentId: 3),
          isTrue);
    });

    test('scenario B: a member proposes THEMSELVES on someone else\'s day',
        () {
      expect(
          requesterParticipates(
              requesterId: 3, scheduledParentId: 1, proposedActualParentId: 3),
          isTrue);
    });

    test('scenario C: a third member proposing someone else is forbidden —'
        ' the proposed person would take the day without consenting', () {
      expect(
          requesterParticipates(
              requesterId: 2, scheduledParentId: 1, proposedActualParentId: 3),
          isFalse);
    });

    test('two-member family always participates', () {
      expect(
          requesterParticipates(
              requesterId: 1, scheduledParentId: 1, proposedActualParentId: 2),
          isTrue);
      expect(
          requesterParticipates(
              requesterId: 2, scheduledParentId: 1, proposedActualParentId: 2),
          isTrue);
    });
  });

  group('normalizeFreeText (F-44)', () {
    test('trims and collapses blank to null', () {
      expect(normalizeFreeText(null), isNull);
      expect(normalizeFreeText(''), isNull);
      expect(normalizeFreeText('   '), isNull);
      expect(normalizeFreeText('Tenho consulta'), 'Tenho consulta');
      expect(normalizeFreeText('  com espaços  '), 'com espaços');
    });
  });

  group('messageSuffix (F-44)', () {
    test('with text appends the labelled message', () {
      expect(messageSuffix('Tenho consulta médica'),
          ' Mensagem: Tenho consulta médica');
    });

    test('without text is empty — no dangling " Mensagem:" label', () {
      expect(messageSuffix(null), '');
      expect(messageSuffix(''), '');
      expect(messageSuffix('   '), '');
    });

    test('is the ONE suffix for approver texts too (QA of F-44)', () {
      // Approval note and rejection reason ride the SAME "Mensagem" suffix —
      // "Observação" is reserved for the day note.
      expect(messageSuffix('Busco às 18h'), ' Mensagem: Busco às 18h');
    });
  });

  group('notesDifferForRevert (F-47)', () {
    test('equivalent texts ask nothing', () {
      expect(notesDifferForRevert(null, null), isFalse);
      expect(notesDifferForRevert('', null), isFalse);
      expect(notesDifferForRevert(null, '   '), isFalse);
      expect(
          notesDifferForRevert('Consulta às 15h', 'Consulta às 15h'), isFalse);
      expect(notesDifferForRevert('  Consulta às 15h  ', 'Consulta às 15h'),
          isFalse);
    });

    test('changed texts ask the question', () {
      // Rewritten after the swap.
      expect(
          notesDifferForRevert('Levar mochila da natação', 'Consulta às 15h'),
          isTrue);
      // The revert would ERASE it.
      expect(notesDifferForRevert('Levar mochila da natação', null), isTrue);
      // The revert would BRING one back.
      expect(notesDifferForRevert(null, 'Consulta às 15h'), isTrue);
      // Case-sensitive: casing is an edit too.
      expect(notesDifferForRevert('consulta às 15h', 'Consulta às 15h'),
          isTrue);
    });
  });

  group('resolve subsets (Home.razor mirrors)', () {
    SwapRequestView req(int id, DateTime date,
            {required int requesting, required int target,
            String status = 'pending'}) =>
        SwapRequestView(
          id: id,
          scheduleDate: date,
          status: status,
          requestingProfileId: requesting,
          targetProfileId: target,
        );

    final d21 = DateTime(2026, 8, 21);
    final d22 = DateTime(2026, 8, 22);
    final d23 = DateTime(2026, 8, 23);
    final open = [
      req(10, d21, requesting: 1, target: 2),
      req(11, d22, requesting: 2, target: 1, status: 'revert_pending'),
      req(12, d23, requesting: 1, target: 3),
    ];

    test('selectedPendingForMe: selected days awaiting MY response', () {
      final mine = selectedPendingForMe(
          openRequests: open, selectedDates: {d21, d22}, myProfileId: 1);
      expect(mine.map((r) => r.id), [11]);
    });

    test('selectedSentByMe: selected days with requests I sent', () {
      final sent = selectedSentByMe(
          openRequests: open, selectedDates: {d21, d22, d23}, myProfileId: 1);
      expect(sent.map((r) => r.id), [10, 12]);
    });

    test('a day outside the selection never joins a subset', () {
      expect(
          selectedPendingForMe(
              openRequests: open, selectedDates: {d23}, myProfileId: 2),
          isEmpty);
    });

    test('null profile (no session) matches nothing', () {
      expect(
          selectedPendingForMe(
              openRequests: open, selectedDates: {d21}, myProfileId: null),
          isEmpty);
      expect(
          selectedSentByMe(
              openRequests: open, selectedDates: {d21}, myProfileId: null),
          isEmpty);
    });

    test('selection comparison is date-only', () {
      final withTime = {DateTime(2026, 8, 21, 14, 30)};
      expect(
          selectedSentByMe(
              openRequests: open, selectedDates: withTime, myProfileId: 1)
              .map((r) => r.id),
          [10]);
    });

    test('isRevertCandidate: future swapped unfrozen day qualifies', () {
      expect(
          isRevertCandidate(
              scheduleDate: _future,
              scheduledParentId: 1,
              actualParentId: 2,
              today: _today,
              frozenDates: const []),
          isTrue);
    });

    test('isRevertCandidate: past, unswapped or frozen days do not', () {
      expect(
          isRevertCandidate(
              scheduleDate: DateTime(2026, 8, 18),
              scheduledParentId: 1,
              actualParentId: 2,
              today: _today,
              frozenDates: const []),
          isFalse);
      expect(
          isRevertCandidate(
              scheduleDate: _future,
              scheduledParentId: 1,
              actualParentId: null,
              today: _today,
              frozenDates: const []),
          isFalse);
      expect(
          isRevertCandidate(
              scheduleDate: _future,
              scheduledParentId: 1,
              actualParentId: 1,
              today: _today,
              frozenDates: const []),
          isFalse);
      expect(
          isRevertCandidate(
              scheduleDate: _future,
              scheduledParentId: 1,
              actualParentId: 2,
              today: _today,
              frozenDates: [_future]),
          isFalse);
    });
  });

  group('frozenDatesOf', () {
    test('derives the date-only set the F-12 guards consume', () {
      final dates = frozenDatesOf([
        SwapRequestView(
            id: 1,
            scheduleDate: DateTime(2026, 8, 21, 10),
            status: 'pending',
            requestingProfileId: 1,
            targetProfileId: 2),
        SwapRequestView(
            id: 2,
            scheduleDate: DateTime(2026, 8, 22),
            status: 'revert_pending',
            requestingProfileId: 2,
            targetProfileId: 1),
      ]);
      expect(dates, {DateTime(2026, 8, 21), DateTime(2026, 8, 22)});
    });
  });

  group('SwapRequestView', () {
    test('isRevertPending discriminates the revert flavor', () {
      SwapRequestView withStatus(String s) => SwapRequestView(
          id: 1,
          scheduleDate: _day,
          status: s,
          requestingProfileId: 1,
          targetProfileId: 2);
      expect(withStatus('revert_pending').isRevertPending, isTrue);
      expect(withStatus('pending').isRevertPending, isFalse);
      expect(withStatus('revert_approved').isRevertPending, isFalse);
    });
  });

  group('parseTimeOfDay', () {
    test('accepts HH:mm and HH:mm:ss', () {
      expect(parseTimeOfDay('08:30'), (hour: 8, minute: 30));
      expect(parseTimeOfDay('18:00:00'), (hour: 18, minute: 0));
    });
    test('rejects absent or malformed values', () {
      expect(parseTimeOfDay(null), isNull);
      expect(parseTimeOfDay(''), isNull);
      expect(parseTimeOfDay('12'), isNull);
      expect(parseTimeOfDay('ab:cd'), isNull);
      expect(parseTimeOfDay('25:00'), isNull);
      expect(parseTimeOfDay('12:75'), isNull);
    });
  });
}
