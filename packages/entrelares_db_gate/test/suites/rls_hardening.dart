import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// T-31 Suite D+ — RLS hardening beyond the day-protection rules: notification
/// privacy, admin-only family rename and the append-only audit log.
///
/// **RLS denials on UPDATE/DELETE are SILENT — they match zero rows.** With no
/// policy, PostgREST answers success and changes nothing, so "expect an
/// exception" passes for the wrong reason and fails for the right one. These
/// tests therefore assert PERSISTENCE, re-reading the row with the service
/// client, never an error.
///
/// Port of `db-gate/Entrelares.IntegrationTests/RlsHardeningTests.cs`.
void rlsHardeningTests(GateFixture fx) {
  group('RlsHardeningTests', () {
    test('the anon key without a session reads nothing from any table',
        () async {
      // S-12 — `anon` has ZERO grants on the application tables. Both outcomes
      // prove it: a permission error (the grant is missing, PostgREST rejects
      // the query) or an empty result (RLS filtered everything). What must never
      // happen is a row coming back.
      const tables = [
        'roles',
        'families',
        'profiles',
        'family_invitations',
        'care_schedules',
        'activity_logs',
        'swap_requests',
        'notifications',
        'auth_elevations',
        'account_logs',
        'family_deletion_requests',
        'family_deletion_responses',
      ];

      final anon = fx.newAnonClient();
      try {
        for (final table in tables) {
          try {
            final rows = await anon.from(table).select();
            expect(rows, isEmpty, reason: '$table leaked rows to anon');
          } on PostgrestException {
            // Rejected outright (permission denied) — the stronger outcome.
          }
        }
      } finally {
        await anon.dispose();
      }
    });

    test('notifications are readable only by their recipient', () async {
      // D8 — the minimal-return insert FOR the other member works (RLS blocks
      // selecting their row back, which is why the client never asks for it),
      // but each user reads only their own.
      final marker = 'e2e-rls-${uniqueMarker()}';
      await fx.founder.from('notifications').insert({
        'recipient_profile_id': fx.memberProfile.id,
        'type': 'swap_requested',
        'title': 'E2E',
        'message': marker,
        'is_read': false,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      final seenByMember = await fx.member.from('notifications').select();
      expect(seenByMember.map((n) => n['message']), contains(marker));

      final seenByFounder = await fx.founder.from('notifications').select();
      expect(seenByFounder.map((n) => n['message']), isNot(contains(marker)));
    });

    test('a non-admin cannot rename the family', () async {
      // D9 — the rename is admin-only, and the RPC is what enforces it.
      await expectRejected(
        () => fx.member.rpc<dynamic>('rename_family',
            params: {'p_name': '${TestEnv.e2eFamilyPrefix}hijacked'}),
        contains: 'Somente administradores',
      );
    });

    test('the activity log is immutable for clients', () async {
      // D10 — append-only: the update and the delete silently affect zero rows
      // and the entry survives unchanged.
      final day = fx.nextFutureDate();
      await fx.founder.from('care_schedules').insert({
        'schedule_date': isoDate(day),
        'scheduled_parent_id': fx.founderProfile.id,
      });

      final logRow = (await fx.founder
              .from('activity_logs')
              .select()
              .eq('affected_date', isoDate(day))
              .limit(1))
          .single;
      final log = ActivityLog.fromJson(logRow);

      await fx.founder
          .from('activity_logs')
          .update({'action': 'tampered'}).eq('id', log.id);
      await fx.founder.from('activity_logs').delete().eq('id', log.id);

      final reloaded = ActivityLog.fromJson(
          (await fx.founder.from('activity_logs').select().eq('id', log.id))
              .single);
      expect(reloaded.action, log.action);
    });
  });
}
