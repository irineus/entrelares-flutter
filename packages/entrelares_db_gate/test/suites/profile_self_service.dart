import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-16 — profile self-service rules at the database level: an own-row name
/// edit works, other rows stay locked (RLS), a role self-edit is blocked,
/// `update_member_name` is admin-only, and the `auth.users → profiles` e-mail
/// sync trigger fires on confirmed e-mail changes.
///
/// Port of `db-gate/Entrelares.IntegrationTests/ProfileSelfServiceTests.cs`.
void profileSelfServiceTests(GateFixture fx) {
  Future<Member> reload(int profileId) async => Member.fromJson(
      (await fx.service.from('profiles').select().eq('id', profileId)).single);

  Future<void> restoreName(int profileId, String name) => fx.service
      .from('profiles')
      .update({'full_name': name}).eq('id', profileId);

  group('ProfileSelfServiceTests', () {
    test('a member updates their own name', () async {
      final original = fx.memberProfile.fullName;
      try {
        await fx.member
            .from('profiles')
            .update({'full_name': 'E2E Member Renamed'}).eq(
                'id', fx.memberProfile.id);

        expect((await reload(fx.memberProfile.id)).fullName,
            'E2E Member Renamed');
      } finally {
        await restoreName(fx.memberProfile.id, original);
      }
    });

    test("a member cannot update another profile directly", () async {
      // RLS answers with SILENCE — zero rows — not with an error, so the
      // assertion has to be that the row is UNTOUCHED.
      await fx.member
          .from('profiles')
          .update({'full_name': 'hacked'}).eq('id', fx.founderProfile.id);

      expect((await reload(fx.founderProfile.id)).fullName,
          fx.founderProfile.fullName);
    });

    test('a non-admin cannot change their own role directly', () async {
      // F-16 guard: the own-row policy is not a side door for role edits.
      final otherRole =
          fx.roles.firstWhere((r) => r.id != fx.memberProfile.roleId);

      await expectRejected(
        () => fx.member
            .from('profiles')
            .update({'role_id': otherRole.id}).eq('id', fx.memberProfile.id),
        contains: 'podem alterar papéis',
      );
    });

    test('update_member_name is admin-only and validates', () async {
      await expectRejected(
        () => fx.member.rpc<dynamic>('update_member_name', params: {
          'p_profile_id': fx.founderProfile.id,
          'p_full_name': 'Novo Nome',
        }),
        contains: 'Somente administradores',
      );

      await expectRejected(
        () => fx.founder.rpc<dynamic>('update_member_name', params: {
          'p_profile_id': fx.memberProfile.id,
          'p_full_name': ' x ',
        }),
        contains: 'entre 2 e 80',
      );

      final original = fx.memberProfile.fullName;
      try {
        await fx.founder.rpc<dynamic>('update_member_name', params: {
          'p_profile_id': fx.memberProfile.id,
          'p_full_name': 'Nome Corrigido',
        });
        expect((await reload(fx.memberProfile.id)).fullName, 'Nome Corrigido');
      } finally {
        await restoreName(fx.memberProfile.id, original);
      }
    });

    test('a confirmed e-mail change syncs profiles.email', () async {
      final userId = fx.memberProfile.userId!;
      final originalEmail = fx.memberProfile.email!;
      final newEmail = fx.testEmail('member-renamed');

      final admin = AdminApi();
      try {
        await admin.updateUserEmail(userId, newEmail);
        expect((await reload(fx.memberProfile.id)).email, newEmail);
      } finally {
        await admin.updateUserEmail(userId, originalEmail);
        admin.close();
      }
    });
  });
}
