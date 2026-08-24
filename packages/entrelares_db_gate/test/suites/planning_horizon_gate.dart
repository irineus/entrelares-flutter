import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-39 — freemium gate: the planning horizon. Free families plan up to 6
/// months ahead; premium up to 24, which is also the ABSOLUTE ceiling for
/// everyone. It is enforced in the `enforce_day_protection` trigger, on the
/// day-write path.
///
/// Grandfather is automatic — a fresh family is premium during its 30-day trial
/// — so the free horizon is exercised by forcing `plan = free` through
/// `set_family_plan`, which clears the trial with it.
///
/// Port of `db-gate/Entrelares.IntegrationTests/PlanningHorizonGateTests.cs`.
void planningHorizonGateTests(GateFixture fx) {
  Future<void> setPlan(int familyId, String plan) => fx.service.rpc<dynamic>(
      'set_family_plan', params: {'p_family_id': familyId, 'p_plan': plan});

  Future<void> insertDay(
      SupabaseClient client, int profileId, int monthsAhead) async {
    final now = today();
    await client.from('care_schedules').insert({
      'schedule_date':
          isoDate(DateTime(now.year, now.month + monthsAhead, now.day)),
      'scheduled_parent_id': profileId,
    });
  }

  group('PlanningHorizonGateTests', () {
    test('a free family is blocked beyond six months', () async {
      final fam = await fx.createFamily('f39-free');
      await setPlan(fam.familyId, 'free');

      // 5 months ahead — comfortably inside the free horizon.
      await insertDay(fam.admin, fam.adminProfile.id, 5);

      // 7 months ahead — past it, refused with the upsell.
      await expectRejected(
        () => insertDay(fam.admin, fam.adminProfile.id, 7),
        contains: 'Premium',
      );
    });

    test('a premium family reaches 24 months, and nobody goes past it',
        () async {
      final fam = await fx.createFamily('f39-prem'); // premium via the trial

      // 12 months ahead — allowed on premium, would be blocked on free.
      await insertDay(fam.admin, fam.adminProfile.id, 12);

      // 25 months ahead — past the absolute ceiling, blocked for everyone.
      await expectRejected(
        () => insertDay(fam.admin, fam.adminProfile.id, 25),
        contains: '24 meses',
      );
    });
  });
}
