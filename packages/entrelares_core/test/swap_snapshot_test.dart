/// The F-26/F-47 snapshot mirror — `ParseSnapshot`/`GetJson*` semantics and
/// the `RestorePreEditStateAsync` branching as a pure plan. The server-side
/// twin is `restore_pre_edit_state` (the 48h auto-approval path); the two
/// must keep making the same decisions from the same `old_data`.
library;

import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

void main() {
  group('PreEditSnapshot.parse', () {
    test('null, blank and malformed input mean "no snapshot"', () {
      expect(PreEditSnapshot.parse(null), isNull);
      expect(PreEditSnapshot.parse(''), isNull);
      expect(PreEditSnapshot.parse('   '), isNull);
      expect(PreEditSnapshot.parse('{not json'), isNull);
    });

    test('accepts a decoded Map (PostgREST jsonb) and a raw JSON string', () {
      final fromMap = PreEditSnapshot.parse({'notes': 'Consulta'});
      final fromString = PreEditSnapshot.parse('{"notes":"Consulta"}');
      expect(fromMap?.notes, 'Consulta');
      expect(fromString?.notes, 'Consulta');
    });

    test('a valid non-object root parses but every field reads null', () {
      // C# TryGetProperty semantics: the snapshot exists, its fields do not.
      final snap = PreEditSnapshot.parse('42');
      expect(snap, isNotNull);
      expect(snap!.stringOf('notes'), isNull);
      expect(snap.intOf('scheduled_parent_id'), isNull);
    });

    test('stringOf: missing key and JSON null both read null; values read as '
        'their string form', () {
      final snap = PreEditSnapshot.parse(
          '{"notes":null,"scheduled_parent_id":5,"handoff_time":"18:00:00"}')!;
      expect(snap.stringOf('missing'), isNull);
      expect(snap.stringOf('notes'), isNull);
      expect(snap.stringOf('scheduled_parent_id'), '5');
      expect(snap.stringOf('handoff_time'), '18:00:00');
    });

    test('intOf parses the string form, null on non-numbers', () {
      final snap =
          PreEditSnapshot.parse('{"a":7,"b":"12","c":"x","d":null}')!;
      expect(snap.intOf('a'), 7);
      expect(snap.intOf('b'), 12);
      expect(snap.intOf('c'), isNull);
      expect(snap.intOf('d'), isNull);
    });

    test('timeOf keeps the wire string only when it parses as a time', () {
      final snap = PreEditSnapshot.parse(
          '{"good":"08:30:00","bad":"25:99","empty":""}')!;
      expect(snap.timeOf('good'), '08:30:00');
      expect(snap.timeOf('bad'), isNull);
      expect(snap.timeOf('empty'), isNull);
      expect(snap.timeOf('missing'), isNull);
    });
  });

  group('revertRestorePlan (RestorePreEditStateAsync branching)', () {
    test('no pre_edit_log_id → clear the actual only (pre-F-26 swaps)', () {
      final plan = revertRestorePlan(
          hasPreEditLogId: false, oldData: null, revertNotes: true);
      expect(plan, isA<RevertClearActualOnly>());
    });

    test('null old_data → the edit CREATED the day → delete it again', () {
      final plan = revertRestorePlan(
          hasPreEditLogId: true, oldData: null, revertNotes: false);
      expect(plan, isA<RevertDeleteDay>());
    });

    test('malformed old_data behaves like null old_data', () {
      final plan = revertRestorePlan(
          hasPreEditLogId: true, oldData: '{broken', revertNotes: false);
      expect(plan, isA<RevertDeleteDay>());
    });

    test('a full snapshot restores scheduled + actual + handoff', () {
      final plan = revertRestorePlan(
        hasPreEditLogId: true,
        oldData:
            '{"scheduled_parent_id":1,"actual_parent_id":2,"handoff_time":"18:00:00","notes":"Antes"}',
        revertNotes: false,
      ) as RevertRestoreFields;
      expect(plan.scheduledParentId, 1);
      expect(plan.actualParentId, 2);
      expect(plan.handoffTime, '18:00:00');
      expect(plan.restoreNotes, isFalse);
      expect(plan.notes, 'Antes');
    });

    test('F-47: the notes travel with the plan but apply only when the '
        'requester asked', () {
      final plan = revertRestorePlan(
        hasPreEditLogId: true,
        oldData: '{"notes":"Antes"}',
        revertNotes: true,
      ) as RevertRestoreFields;
      expect(plan.restoreNotes, isTrue);
      expect(plan.notes, 'Antes');
      // Snapshot without the fields: keep-current semantics for scheduled,
      // null (clear) for actual/handoff — exactly the C# `??` shape.
      expect(plan.scheduledParentId, isNull);
      expect(plan.actualParentId, isNull);
      expect(plan.handoffTime, isNull);
    });
  });

  group('notesDifferForRevert on snapshot notes (F-47)', () {
    test('a snapshot whose notes match the current text asks nothing', () {
      final snap = PreEditSnapshot.parse('{"notes":"Consulta às 15h"}')!;
      expect(notesDifferForRevert('Consulta às 15h', snap.notes), isFalse);
    });

    test('an erased-or-rewritten observation asks the question', () {
      final snap = PreEditSnapshot.parse('{"notes":null}')!;
      expect(notesDifferForRevert('Levar mochila', snap.notes), isTrue);
    });
  });
}
