import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-40 — Gestor (free) vs Administrador (premium override).
///
/// The RETROACTIVE override of a PAST day is the premium power: a free admin
/// fixes only the last `override_free_days` (7); premium reaches back
/// `override_premium_months` (6), which is the hard cap for everyone. It is
/// enforced in the `enforce_day_protection` past-day check. Frozen days, planned
/// future days and clearing stay free (unchanged).
///
/// Fixture families are premium via their trial, so the free window is exercised
/// by forcing `plan = free`.
///
/// Port of `db-gate/Entrelares.IntegrationTests/AdminOverrideTierTests.cs`.
void adminOverrideTierTests(GateFixture fx) {
  Future<void> setPlan(int familyId, String plan) => fx.service.rpc<dynamic>(
      'set_family_plan', params: {'p_family_id': familyId, 'p_plan': plan});

  /// Seeds a past day through the service role, which bypasses the
  /// day-protection trigger — the only way to build the precondition at all.
  Future<DateTime> seedPastDay(int scheduledParentId, int daysAgo) async {
    final date = addDays(today(), -daysAgo);
    await fx.service.from('care_schedules').insert({
      'schedule_date': isoDate(date),
      'scheduled_parent_id': scheduledParentId,
    });
    return date;
  }

  /// A BENIGN edit (the observation) — it fires the past-day check without
  /// touching the S-09 planned-parent rule, so a refusal can only be about the
  /// window under test.
  Future<void> editNotes(
      SupabaseClient client, DateTime date, String notes) async {
    final row = await readDay(client, date);
    await saveDay(client, row.copyWith(notes: notes));
  }

  group('AdminOverrideTierTests', () {
    test('a free admin fixes the recent past and is blocked beyond the window',
        () async {
      final fam = await fx.createFamily('f40-free');
      await setPlan(fam.familyId, 'free');

      // 3 days ago — inside the 7-day free window.
      final recent = await seedPastDay(fam.adminProfile.id, 3);
      await editNotes(fam.admin, recent, 'corrigido');

      // 30 days ago — beyond it, refused with the upsell.
      final old = await seedPastDay(fam.adminProfile.id, 30);
      await expectRejected(() => editNotes(fam.admin, old, 'x'),
          contains: 'Premium');
    });

    test('a premium admin reaches the cap and is blocked beyond it', () async {
      final fam = await fx.createFamily('f40-prem'); // premium via the trial

      // 30 days ago — well inside 6 months.
      final old = await seedPastDay(fam.adminProfile.id, 30);
      await editNotes(fam.admin, old, 'corrigido');

      // ~7 months ago — past the 6-month retroactive cap, blocked for everyone.
      final ancient = await seedPastDay(fam.adminProfile.id, 220);
      await expectRejected(() => editNotes(fam.admin, ancient, 'x'),
          contains: 'meses');
    });
  });
}
