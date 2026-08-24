import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

/// Suite D — RLS multi-tenancy (F-14/S-06): family A must never see or touch
/// family B's data, whatever the client sends.
///
/// Port of `db-gate/Entrelares.IntegrationTests/FamilyIsolationTests.cs`.
void familyIsolationTests(GateFixture fx) {
  group('FamilyIsolationTests', () {
    test('profiles are scoped to the caller\'s own family', () async {
      final rows = await fx.member.from('profiles').select();
      final seenByA = [for (final row in rows) Member.fromJson(row)];

      expect(seenByA, isNotEmpty);
      for (final profile in seenByA) {
        expect(profile.familyId, fx.familyId);
      }
      expect(seenByA.map((p) => p.id), isNot(contains(fx.founderBProfile.id)));
    });

    test("another family's schedules are invisible", () async {
      final dateB = fx.nextFutureDate();
      await fx.founderB.from('care_schedules').insert({
        'schedule_date': isoDate(dateB),
        'scheduled_parent_id': fx.founderBProfile.id,
      });

      final seenByA = await fx.member
          .from('care_schedules')
          .select()
          .eq('schedule_date', isoDate(dateB));

      expect(seenByA, isEmpty);
    });

    test("a schedule cannot be created for another family's member", () async {
      // The family_id is stamped server-side from the scheduled parent's
      // profile — pointing at family B's member must be rejected (RLS).
      await expectLater(
        fx.member.from('care_schedules').insert({
          'schedule_date': isoDate(fx.nextFutureDate()),
          'scheduled_parent_id': fx.founderBProfile.id,
        }),
        throwsA(isA<PostgrestException>()),
      );
    });
  });
}
