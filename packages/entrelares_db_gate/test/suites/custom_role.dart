import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-41 — custom per-family roles (Premium). Creation is admin + Premium and
/// ADD-ONLY (existing custom roles keep working on free, like F-37); deletion is
/// admin + unused-only; RLS and the RPC's own scope guards keep one family's
/// custom rows invisible and unassignable to another.
///
/// Grandfather is automatic — a fresh family is premium via its 30-day trial —
/// so the gate is exercised by forcing `plan = free`, which clears the trial with
/// it.
///
/// Port of `db-gate/Entrelares.IntegrationTests/CustomRoleTests.cs`.
void customRoleTests(GateFixture fx) {
  Future<void> setPlan(int familyId, String plan) => fx.service.rpc<dynamic>(
      'set_family_plan', params: {'p_family_id': familyId, 'p_plan': plan});

  Future<int> createCustomRole(SupabaseClient caller, String label,
      {String? emoji}) async {
    final result = await caller.rpc<dynamic>('create_custom_role', params: {
      'p_label': label,
      'p_emoji': ?emoji,
    });
    return result is int ? result : int.parse(result.toString());
  }

  Future<void> setMemberRole(
          SupabaseClient caller, int profileId, int roleId) =>
      caller.rpc<dynamic>('set_member_role',
          params: {'p_profile_id': profileId, 'p_role_id': roleId});

  Future<void> deleteCustomRole(SupabaseClient caller, int roleId) =>
      caller.rpc<dynamic>('delete_custom_role', params: {'p_role_id': roleId});

  Future<void> updateCustomRole(SupabaseClient caller, int roleId, String label,
          {String? emoji}) =>
      caller.rpc<dynamic>('update_custom_role', params: {
        'p_role_id': roleId,
        'p_label': label,
        'p_emoji': ?emoji,
      });

  Future<List<Role>> rolesSeenBy(SupabaseClient who) async =>
      [for (final row in await who.from('roles').select()) Role.fromJson(row)];

  group('CustomRoleTests', () {
    test('a free family cannot create, and premium unblocks the same creation',
        () async {
      final fam = await fx.createFamily('f41-free');
      await setPlan(fam.familyId, 'free');

      await expectRejected(
        () => createCustomRole(fam.admin, 'E2E Papel Bloqueado'),
        contains: 'Premium',
      );

      await setPlan(fam.familyId, 'premium');
      final roleId =
          await createCustomRole(fam.admin, 'E2E Papel Liberado', emoji: '🦉');
      expect(roleId, greaterThan(0));

      final created =
          (await rolesSeenBy(fam.admin)).firstWhere((r) => r.id == roleId);
      expect(created.isCustom, isTrue);
      expect(created.roleName, 'E2E Papel Liberado');
      expect(created.emoji, '🦉');
    });

    test('creation is admin-only, even on a premium family', () async {
      final fam = await fx.createFamily('f41-nonadm');

      await expectRejected(
        () => createCustomRole(fam.member, 'E2E Papel do Membro'),
        contains: 'administradores',
      );
    });

    test('a custom role is invisible AND unassignable to another family',
        () async {
      // Two guards, and both matter: RLS hides the row, and the RPCs refuse the
      // id even when a caller guesses it — invisibility alone would leave the
      // id itself as the attack.
      final roleId = await createCustomRole(fx.founder, 'E2E Papel Exclusivo A');

      expect((await rolesSeenBy(fx.founderB)).map((r) => r.id),
          isNot(contains(roleId)));

      await expectRejected(
        () => GateFixture.createInvitation(
            fx.founderB, fx.testEmail('f41-cross'), roleId),
        contains: 'Papel inválido',
      );

      await expectRejected(
        () => setMemberRole(fx.founderB, fx.founderBProfile.id, roleId),
        contains: 'Papel inválido',
      );
    });

    test('a duplicate label is refused, case-insensitively', () async {
      // Against the family's own custom labels AND the built-in vocabulary.
      await createCustomRole(fx.founder, 'E2E Papel Duplicado');

      await expectRejected(
        () => createCustomRole(fx.founder, 'e2e papel DUPLICADO'),
        contains: 'Já existe',
      );

      await expectRejected(
        () => createCustomRole(fx.founder, 'Avó'),
        contains: 'Já existe',
      );
    });

    test('deletion is blocked while in use and allowed once unused', () async {
      final fam = await fx.createFamily('f41-del');
      final roleId = await createCustomRole(fam.admin, 'E2E Papel Temporário');
      final originalRoleId = fam.memberProfile.roleId!;

      await setMemberRole(fam.admin, fam.memberProfile.id, roleId);
      await expectRejected(() => deleteCustomRole(fam.admin, roleId),
          contains: 'em uso');

      await setMemberRole(fam.admin, fam.memberProfile.id, originalRoleId);
      await deleteCustomRole(fam.admin, roleId);

      expect((await rolesSeenBy(fam.admin)).map((r) => r.id),
          isNot(contains(roleId)));
    });

    test("built-ins and other families' rows are out of delete's reach",
        () async {
      await expectRejected(
        () => deleteCustomRole(fx.founder, fx.roleId('grandmother')),
        contains: 'não encontrado',
      );

      final roleId = await createCustomRole(fx.founder, 'E2E Papel Indelével');
      await expectRejected(() => deleteCustomRole(fx.founderB, roleId),
          contains: 'não encontrado');
    });

    test('a premium admin renames an IN-USE role, and an omitted emoji clears '
        'it', () async {
      // Renaming a role somebody holds is allowed BY DESIGN: `role_id` is the
      // identity, the label is only how it reads.
      final fam = await fx.createFamily('f41-upd');
      final roleId =
          await createCustomRole(fam.admin, 'E2E Papel Original', emoji: '🦉');
      await setMemberRole(fam.admin, fam.memberProfile.id, roleId);

      await updateCustomRole(fam.admin, roleId, 'E2E Papel Renomeado');

      final updated =
          (await rolesSeenBy(fam.admin)).firstWhere((r) => r.id == roleId);
      expect(updated.roleName, 'E2E Papel Renomeado');
      expect(updated.emoji, isNull);

      // The member still holds the same role id — only the label moved.
      final member = Member.fromJson((await fam.admin
              .from('profiles')
              .select()
              .eq('id', fam.memberProfile.id))
          .single);
      expect(member.roleId, roleId);
    });

    test('editing is Premium, unlike deletion', () async {
      // Owner decision: a family that lapses can still tidy up (delete an unused
      // role) but cannot keep authoring.
      final fam = await fx.createFamily('f41-updfree');
      final roleId = await createCustomRole(fam.admin, 'E2E Papel Congelado');
      await setPlan(fam.familyId, 'free');

      await expectRejected(
        () => updateCustomRole(fam.admin, roleId, 'E2E Papel Alterado'),
        contains: 'Premium',
      );
    });

    test('a rename cannot duplicate or reach another family', () async {
      final roleId = await createCustomRole(fx.founder, 'E2E Papel Editável');

      await expectRejected(() => updateCustomRole(fx.founder, roleId, 'Avó'),
          contains: 'Já existe');

      await expectRejected(
        () => updateCustomRole(fx.founderB, roleId, 'E2E Papel Roubado'),
        contains: 'não encontrado',
      );

      await expectRejected(
        () => updateCustomRole(
            fx.founder, fx.roleId('grandmother'), 'E2E Papel Sobrescrito'),
        contains: 'não encontrado',
      );
    });

    test('a family that drops to free KEEPS its custom roles', () async {
      // Add-only grandfather: the gate is on CREATION, so a lapsed family never
      // finds its own vocabulary taken away from it.
      final fam = await fx.createFamily('f41-keep');
      final roleId = await createCustomRole(fam.admin, 'E2E Papel Herdado');

      await setPlan(fam.familyId, 'free');

      expect((await rolesSeenBy(fam.admin)).map((r) => r.id), contains(roleId));

      // Still assignable on free.
      await setMemberRole(fam.admin, fam.memberProfile.id, roleId);
      final member = Member.fromJson((await fam.admin
              .from('profiles')
              .select()
              .eq('id', fam.memberProfile.id))
          .single);
      expect(member.roleId, roleId);
    });
  });
}
