import 'dart:math';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// Suite D — the day-protection rules live in the DATABASE (V008 + S-09). These
/// tests hit PostgREST directly, proving no UI shortcut can evade them, and
/// every expected failure asserts on the trigger's own PT-BR message: a rule
/// that fires for the wrong reason is a different bug from one that never
/// fires.
///
/// Port of `db-gate/Entrelares.IntegrationTests/DayProtectionTests.cs`.
void dayProtectionTests(GateFixture fx) {
  Future<CareSchedule> seedDay(SupabaseClient creator, int scheduledParentId,
      {DateTime? date}) async {
    final rows = await creator.from('care_schedules').insert({
      'schedule_date': isoDate(date ?? fx.nextFutureDate()),
      'scheduled_parent_id': scheduledParentId,
    }).select();
    return CareSchedule.fromJson(rows.single);
  }

  group('DayProtectionTests', () {
    test('a non-admin cannot change the scheduled parent of an assigned day',
        () async {
      // S-09: the planned schedule is immutable for regular users.
      final day = await seedDay(fx.founder, fx.founderProfile.id);

      await expectRejected(
        () => saveDay(
            fx.member, day.copyWith(scheduledParentId: fx.memberProfile.id)),
        contains: 'responsável planejado só pode ser alterado',
      );
    });

    test('a non-admin cannot delete an assigned day, and an admin can',
        () async {
      // QA (July 2026): the delete-and-recreate bypass of S-09 is closed —
      // clearing an ASSIGNED day is admin-only.
      final day = await seedDay(fx.founder, fx.founderProfile.id);

      await expectRejected(
        () => fx.member.from('care_schedules').delete().eq('id', day.id),
        contains: 'só pode ser limpo por um administrador',
      );

      final still =
          await fx.member.from('care_schedules').select().eq('id', day.id);
      expect(still, hasLength(1));

      // The admin (founder) may — the F-14 bypass.
      await fx.founder.from('care_schedules').delete().eq('id', day.id);
      final gone =
          await fx.founder.from('care_schedules').select().eq('id', day.id);
      expect(gone, isEmpty);
    });

    test('a non-admin cannot set the actual parent directly on a future day',
        () async {
      // F-12/S-05: creating a swap directly (actual ≠ scheduled) is
      // workflow-only.
      final day = await seedDay(fx.founder, fx.founderProfile.id);

      await expectRejected(
        () => saveDay(
            fx.member, day.copyWith(actualParentId: fx.memberProfile.id)),
        contains: 'fluxo de aprovação',
      );
    });

    test('an ADMIN cannot set the actual parent directly on a future day',
        () async {
      // F-14 decision: on FUTURE days the workflow binds admins too. This is
      // the pair to the test above, and the reason both exist: the admin bypass
      // is deliberate in some rules and deliberately absent in this one.
      final day = await seedDay(fx.founder, fx.founderProfile.id);

      await expectRejected(
        () => saveDay(
            fx.founder, day.copyWith(actualParentId: fx.memberProfile.id)),
        contains: 'fluxo de aprovação',
      );
    });

    test('a non-admin cannot edit a past day', () async {
      // F-13. The BAND is the point, not the randomness. The C# version started
      // at `today-3 - Random(1000)` — and today-3 is exactly the date the 84 h
      // auto-approval seed computes, so a draw of 0 collided inside the SHARED
      // family and turned the whole gate red with a 23505 (1-in-1000 per run).
      // The randomisation was there to dodge collisions and instead had one
      // deterministic seed sitting on its floor.
      //
      // This test needs A past day, never a particular one, so it takes a band
      // no other seed can reach: the furthest deterministic past date in the
      // suite is 47 days, and the 220-day one lives in a throwaway family.
      final pastDate =
          addDays(today(), -400 - Random().nextInt(600));
      final day = await seedDay(fx.service, fx.founderProfile.id, date: pastDate);

      await expectRejected(
        () => saveDay(fx.member, day.copyWith(notes: 'tentativa de edição')),
        contains: 'Dias passados',
      );
    });

    test('a non-admin cannot edit a frozen day', () async {
      // F-12: a day with a pending request is frozen for everyone but the
      // target and the admins.
      final day = await seedDay(fx.founder, fx.founderProfile.id);

      // The member requests the swap, making the FOUNDER the target — so the
      // member is neither target nor admin.
      await fx.member.from('swap_requests').insert({
        'schedule_date': isoDate(day.scheduleDate),
        'schedule_id': day.id,
        'requesting_profile_id': fx.memberProfile.id,
        'target_profile_id': fx.founderProfile.id,
        'previous_actual_parent_id': null,
        'proposed_actual_parent_id': fx.memberProfile.id,
        'status': 'pending',
      });

      await expectRejected(
        () => saveDay(
            fx.member, day.copyWith(notes: 'tentativa em dia congelado')),
        contains: 'solicitação pendente',
      );
    });

    test('a non-admin cannot delete a day carrying an approved swap', () async {
      // An approved swap is a day whose actual differs from its scheduled
      // parent; the service client seeds that state directly.
      final date = fx.nextFutureDate();
      await fx.service.from('care_schedules').insert({
        'schedule_date': isoDate(date),
        'scheduled_parent_id': fx.founderProfile.id,
        'actual_parent_id': fx.memberProfile.id,
      });

      await expectRejected(
        () => fx.member
            .from('care_schedules')
            .delete()
            .eq('schedule_date', isoDate(date)),
        contains: 'troca aprovada',
      );
    });
  });
}
