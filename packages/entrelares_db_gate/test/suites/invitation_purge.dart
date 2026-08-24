import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// S-15/A-4 — `purge_stale_invitations()`.
///
/// The invitation e-mail promises: *"Caso este convite não seja aceito, seu
/// registro será permanentemente expurgado de nossos sistemas em até 30 dias."*
/// These tests are what keep that sentence true — and, just as importantly, what
/// stop the purge from eating the rows `profiles.joined_via_invite` is derived
/// from.
///
/// Port of `db-gate/Entrelares.IntegrationTests/InvitationPurgeTests.cs`.
void invitationPurgeTests(GateFixture fx) {
  Future<void> backdate(int id, int ageDays) => fx.service
      .from('family_invitations')
      .update({
        'created_at': DateTime.now()
            .toUtc()
            .subtract(Duration(days: ageDays))
            .toIso8601String(),
      })
      .eq('id', id);

  /// Invitations are created through the REAL RPC — never hand-inserted: the
  /// table has server-side defaults and a unique token — and then aged with a
  /// targeted update.
  Future<int> seedPending(
      SupabaseClient inviter, int roleId, String tag, int ageDays) async {
    final token = await GateFixture.createInvitation(
        inviter, fx.testEmail('purge-$tag'), roleId);
    final row = (await fx.service
            .from('family_invitations')
            .select('id')
            .eq('token', token))
        .single;
    final id = row['id'] as int;
    await backdate(id, ageDays);
    return id;
  }

  Future<bool> exists(int id) async =>
      (await fx.service.from('family_invitations').select('id').eq('id', id))
          .isNotEmpty;

  Future<void> purge() => fx.service.rpc<dynamic>('purge_stale_invitations');

  group('InvitationPurgeTests', () {
    test('never accepted and older than 30 days is purged', () async {
      final fam = await fx.createFamily('invpg1');
      final stale =
          await seedPending(fam.admin, fx.roleId('aunt'), 'stale', 31);

      await purge();

      expect(await exists(stale), isFalse);
    });

    test('never accepted and inside the window survives', () async {
      // The promise is "em até 30 dias", and the two periods in the e-mail are
      // different things: the LINK dies at 7 days, the RECORD at 30. This pins
      // that gap — the exact point the complementary legal opinion had to
      // settle.
      final fam = await fx.createFamily('invpg2');
      final recent =
          await seedPending(fam.admin, fx.roleId('aunt'), 'recent', 10);

      await purge();

      expect(await exists(recent), isTrue);
    });

    test('an accepted invitation is never purged, however ancient', () async {
      // THE one that protects S-15/A-1. An ACCEPTED invitation is the evidence
      // that its owner joined BY INVITE — `set_joined_via_invite()` looks the
      // e-mail up in this very table on profile INSERT. Purging it would
      // silently reclassify that person as a family CREATOR and show them the
      // wrong legal declaration on the re-consent screen.
      //
      // Age must not matter, so this backdates the fixture's own REAL accepted
      // invitation far past the window.
      final fam = await fx.createFamily('invpg3');

      final accepted = FamilyInvitation.fromJson((await fx.service
              .from('family_invitations')
              .select()
              .eq('family_id', fam.familyId)
              .not('accepted_at', 'is', null))
          .single);

      await backdate(accepted.id, 400);
      await purge();

      expect(await exists(accepted.id), isTrue);

      // And the marker it feeds is intact.
      final member = Member.fromJson((await fx.service
              .from('profiles')
              .select()
              .eq('id', fam.memberProfile.id))
          .single);
      expect(member.joinedViaInvite, isTrue);
    });

    test('the purge is refused for an authenticated caller', () async {
      // Service-role only: the function is SECURITY DEFINER and deletes ACROSS
      // families, so a logged-in user reaching it would be a cross-tenant delete
      // primitive.
      final fam = await fx.createFamily('invpg4');

      await expectRejected(
          () => fam.member.rpc<dynamic>('purge_stale_invitations'));
    });
  });
}
