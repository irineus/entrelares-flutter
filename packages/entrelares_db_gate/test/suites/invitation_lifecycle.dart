import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

/// T-31 Suite A — the invitation lifecycle rules that live in the database:
/// revoke/resend token invalidation, and the anon-facing `get_invite_info` RPC
/// the pre-auth register page depends on.
///
/// Port of `db-gate/Entrelares.IntegrationTests/InvitationLifecycleTests.cs`.
void invitationLifecycleTests(GateFixture fx) {
  /// The family name behind [token], asked ANONYMOUSLY — exactly how the
  /// register page calls it before any session exists. Null when the token is
  /// not a live pending invitation: unknown, accepted, revoked and expired are
  /// deliberately indistinguishable, which is what keeps the RPC from being an
  /// enumeration oracle.
  Future<String?> inviteFamilyName(String token) async {
    final anon = fx.newAnonClient();
    try {
      final result = await anon
          .rpc<dynamic>('get_invite_info', params: {'p_token': token});
      if (result is List && result.isNotEmpty) {
        return (result.first as Map)['family_name'] as String?;
      }
      return null;
    } finally {
      await anon.dispose();
    }
  }

  group('InvitationLifecycleTests', () {
    test('revoking and resending invalidate the older tokens', () async {
      // Runs on family B — the only one with a free seat to invite into.
      final email = fx.testEmail('lifecycle');
      final auntId = fx.roleId('aunt');

      final token1 =
          await GateFixture.createInvitation(fx.founderB, email, auntId);
      expect(await inviteFamilyName(token1), isNotNull);

      final invitation = (await fx.service
              .from('family_invitations')
              .select('id')
              .eq('token', token1))
          .single;
      await fx.founderB.rpc<dynamic>('revoke_invitation',
          params: {'p_invitation_id': invitation['id']});
      expect(await inviteFamilyName(token1), isNull);

      // Resend twice: the newest token wins, the previous one dies.
      final token2 =
          await GateFixture.createInvitation(fx.founderB, email, auntId);
      final token3 =
          await GateFixture.createInvitation(fx.founderB, email, auntId);
      expect(token3, isNot(token2));
      expect(await inviteFamilyName(token2), isNull);
      expect(await inviteFamilyName(token3), isNotNull);
    });

    test('get_invite_info answers anonymously and hides garbage', () async {
      final token = await GateFixture.createInvitation(
          fx.founderB, fx.testEmail('info'), fx.roles.first.id);

      expect(await inviteFamilyName(token),
          startsWith(TestEnv.e2eFamilyPrefix));

      expect(await inviteFamilyName('11111111-2222-4333-8444-555555555555'),
          isNull);
    });

    // The old two-member cap was superseded by F-28: the cap is now 4 seats
    // (members + open invitations), covered by the multi-caregiver suite.
  });
}
