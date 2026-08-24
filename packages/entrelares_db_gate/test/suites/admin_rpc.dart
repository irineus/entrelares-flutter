import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// Suite D — the SECURITY DEFINER RPCs and onboarding rules: the admin
/// invariants (F-14), role management (F-27) and invitation single-use
/// (F-15/V009). All enforced server-side.
///
/// Port of `db-gate/Entrelares.IntegrationTests/AdminRpcTests.cs`.
void adminRpcTests(GateFixture fx) {
  group('AdminRpcTests', () {
    test('the last admin cannot be demoted', () async {
      // F-14: every family keeps at least one admin. S-10 put an elevation in
      // front of the RPC, so the call has to be elevated to REACH the invariant
      // — otherwise it would be refused for the wrong reason.
      await fx.elevate(fx.founderProfile);

      await expectRejected(
        () => fx.founder.rpc<dynamic>('set_member_admin', params: {
          'p_profile_id': fx.founderProfile.id,
          'p_is_admin': false,
        }),
        contains: 'pelo menos uma pessoa administradora',
      );
    });

    test('a non-admin cannot change roles', () async {
      await expectRejected(
        () => fx.member.rpc<dynamic>('set_member_role', params: {
          'p_profile_id': fx.founderProfile.id,
          'p_role_id': fx.roles.first.id,
        }),
        contains: 'Somente administradores',
      );
    });

    test('a role that is not in the catalog is rejected', () async {
      await expectRejected(
        () => fx.founder.rpc<dynamic>('set_member_role', params: {
          'p_profile_id': fx.memberProfile.id,
          'p_role_id': 999999,
        }),
        contains: 'Papel inválido',
      );
    });

    test('an admin changes a member role, and back', () async {
      final auntId = fx.roleId('aunt');
      final original = fx.memberProfile.roleId;

      try {
        await fx.founder.rpc<dynamic>('set_member_role', params: {
          'p_profile_id': fx.memberProfile.id,
          'p_role_id': auntId,
        });

        final refreshed = Member.fromJson((await fx.founder
                .from('profiles')
                .select()
                .eq('id', fx.memberProfile.id))
            .single);
        expect(refreshed.roleId, auntId);
      } finally {
        await fx.founder.rpc<dynamic>('set_member_role', params: {
          'p_profile_id': fx.memberProfile.id,
          'p_role_id': original,
        });
      }
    });

    test('an accepted invitation token cannot onboard another user', () async {
      // F-15/V009: single use. The token the fixture's own member joined with is
      // replayed here, which is the honest version of the attack — a token that
      // really was valid once.
      final admin = AdminApi();
      try {
        await expectRejected(() => admin.createConfirmedUser(
              fx.testEmail('intruder'),
              fx.password,
              {
                'full_name': 'E2E Intruder',
                'invite_token': fx.inviteToken,
              },
            ));
      } finally {
        admin.close();
      }
    });
  });
}
