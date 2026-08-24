import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

/// S-15/A-1 — the marker that decides WHICH declaration a profile is shown.
///
/// The legal review split the two ways into a family: whoever CREATES it accepts
/// a ciência/responsabilidade term (the system has no dedicated child fields);
/// whoever is INVITED accepts confidentiality instead, holding no parental
/// authority. The register screen knows which path it is; the re-consent gate,
/// running for profiles created long ago, does not — so the marker is persisted.
///
/// These tests pin the DB half: the trigger classifies new sign-ups correctly,
/// and the classification survives the paths that could plausibly corrupt it.
///
/// Port of `db-gate/Entrelares.IntegrationTests/JoinedViaInviteTests.cs`.
void joinedViaInviteTests(GateFixture fx) {
  Future<Member> profileById(int id) async => Member.fromJson(
      (await fx.service.from('profiles').select().eq('id', id)).single);

  group('JoinedViaInviteTests', () {
    test('the founder is not an invitee and the member is', () async {
      final fam = await fx.createFamily('jvi');

      expect((await profileById(fam.adminProfile.id)).joinedViaInvite, isFalse);
      expect((await profileById(fam.memberProfile.id)).joinedViaInvite, isTrue);
    });

    test('a third caregiver joining later is also marked as invited', () async {
      // The marker is about HOW you entered, not about being first or holding
      // admin.
      final third = await fx.ensureThirdMember();

      expect((await profileById(third.id)).joinedViaInvite, isTrue);
    });

    test("the fixture's own founder is not marked as invited", () async {
      // Guards against a backfill or trigger rule that matches too broadly —
      // e.g. ANY invitation in the family rather than one to this e-mail.
      expect((await profileById(fx.founderProfile.id)).joinedViaInvite, isFalse);
    });

    test('a member cannot flip the marker on their own row', () async {
      // It decides which legal declaration a user is asked to accept, so a
      // profile able to flip its own value could route itself to the weaker
      // text. The client CAN edit its own profile (name, language), so the
      // column is frozen by the TRIGGER instead — silently, because raising
      // would break an ordinary edit that happens to send the whole row back.
      // The write is therefore accepted and simply has no effect, which is why
      // the assertion is on the stored value.
      await fx.member
          .from('profiles')
          .update({'joined_via_invite': false}).eq('id', fx.memberProfile.id);

      expect((await profileById(fx.memberProfile.id)).joinedViaInvite, isTrue);
    });

    test('the service role cannot flip it either', () async {
      // The freeze is in the trigger, not in a policy. Worth pinning: it means a
      // stray admin or script cannot quietly change which declaration a user is
      // shown.
      await fx.service
          .from('profiles')
          .update({'joined_via_invite': false}).eq('id', fx.memberProfile.id);

      expect((await profileById(fx.memberProfile.id)).joinedViaInvite, isTrue);
    });
  });
}
