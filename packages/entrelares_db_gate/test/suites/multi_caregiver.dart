import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-28 (PR1) — the multi-caregiver membership rules that live in the database:
/// the 4-seat cap (members + open invitations), per-e-mail resend revocation
/// (inviting B must NOT kill A's pending invite), and a third member joining
/// through the real invitation flow.
///
/// The acceptance-time cap in `handle_new_user` is defence in depth only:
/// because every open invitation reserves a seat at CREATION and expired or
/// revoked tokens cannot be accepted, the creation-time check already guarantees
/// the invariant — so it is not worth three extra GoTrue users.
///
/// Port of `db-gate/Entrelares.IntegrationTests/MultiCaregiverTests.cs`.
void multiCaregiverTests(GateFixture fx) {
  Future<bool> tokenIsAlive(String token) async {
    final anon = fx.newAnonClient();
    try {
      final result = await anon
          .rpc<dynamic>('get_invite_info', params: {'p_token': token});
      return result is List && result.isNotEmpty;
    } finally {
      await anon.dispose();
    }
  }

  /// Family B accumulates open invitations from other scenarios in this run —
  /// start each one from a clean slate, and leave it clean.
  Future<void> revokeAllOpenInvitations(
      int familyId, SupabaseClient admin) async {
    final open = await fx.service
        .from('family_invitations')
        .select('id')
        .eq('family_id', familyId)
        .isFilter('accepted_at', null)
        .isFilter('revoked_at', null);
    for (final row in open) {
      await admin.rpc<dynamic>('revoke_invitation',
          params: {'p_invitation_id': row['id']});
    }
  }

  group('MultiCaregiverTests', () {
    test('a third caregiver joins through the invitation flow', () async {
      final third = await fx.ensureThirdMember();

      final seenByFounder = [
        for (final row in await fx.founder.from('profiles').select())
          Member.fromJson(row)
      ];
      expect(seenByFounder.map((p) => p.id), contains(third.id));
      expect(third.roleId, fx.roleId('grandmother'));
      expect(third.isAdmin, isFalse);
      expect(third.familyId, fx.familyId);
    });

    test('open invitations coexist, and a resend is per e-mail', () async {
      await revokeAllOpenInvitations(fx.familyBId, fx.founderB);
      final roleId = fx.roles.first.id;
      final emailX = fx.testEmail('multi-x');
      final emailY = fx.testEmail('multi-y');

      final tokenX =
          await GateFixture.createInvitation(fx.founderB, emailX, roleId);
      final tokenY1 =
          await GateFixture.createInvitation(fx.founderB, emailY, roleId);

      // Both invitations are open at the same time — impossible before F-28.
      expect(await tokenIsAlive(tokenX), isTrue);
      expect(await tokenIsAlive(tokenY1), isTrue);

      // Resend to Y: Y's old token dies, X's invitation is untouched.
      final tokenY2 =
          await GateFixture.createInvitation(fx.founderB, emailY, roleId);
      expect(await tokenIsAlive(tokenY1), isFalse);
      expect(await tokenIsAlive(tokenY2), isTrue);
      expect(await tokenIsAlive(tokenX), isTrue);

      await revokeAllOpenInvitations(fx.familyBId, fx.founderB);
    });

    test('a pending swap is visible to the uninvolved caregiver', () async {
      // QA fix — the third caregiver's calendar must freeze the day too, so the
      // family-scoped SELECT has to reach them. The old requester/target-only
      // policy hid it from observers.
      final third = await fx.ensureThirdMember();
      final day = fx.nextFutureDate();

      await fx.founder.from('care_schedules').insert({
        'schedule_date': isoDate(day),
        'scheduled_parent_id': fx.founderProfile.id,
      });
      await fx.member.from('swap_requests').insert({
        'schedule_date': isoDate(day),
        'requesting_profile_id': fx.memberProfile.id,
        'target_profile_id': fx.founderProfile.id,
        'proposed_actual_parent_id': fx.memberProfile.id,
        'status': 'pending',
      });

      final thirdClient = await fx.ensureThirdClient();
      final seen = await thirdClient
          .from('swap_requests')
          .select()
          .eq('schedule_date', isoDate(day));
      expect(seen.map((r) => r['status']), contains('pending'));
      expect(third.id, isNotNull);

      // Do not leak a frozen day into the rest of the run.
      await fx.service
          .from('swap_requests')
          .delete()
          .eq('family_id', fx.familyId)
          .eq('schedule_date', isoDate(day));
    });

    test('the seat cap blocks an invitation beyond four seats', () async {
      // Seats = members + OPEN invitations. Counting the invitations is the
      // whole point: a family could otherwise queue five invites and blow past
      // the cap the moment they were all accepted.
      await revokeAllOpenInvitations(fx.familyBId, fx.founderB);
      final roleId = fx.roles.first.id;

      final members = (await fx.founderB.from('profiles').select()).length;
      for (var i = 0; i < 4 - members; i++) {
        await GateFixture.createInvitation(
            fx.founderB, fx.testEmail('cap-$i'), roleId);
      }

      await expectRejected(
        () => GateFixture.createInvitation(
            fx.founderB, fx.testEmail('cap-overflow'), roleId),
        contains: 'limite de 4',
      );

      await revokeAllOpenInvitations(fx.familyBId, fx.founderB);
    });
  });
}
