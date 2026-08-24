import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-37 — the freemium gate: a free family includes TWO caregivers; the 3rd+ is
/// Premium (add-only + grandfather). It is enforced in `create_invitation`, the
/// admin-facing primary guard. The `handle_new_user` backstop is identical logic
/// and, per the multi-caregiver rationale, not worth extra GoTrue users to
/// re-prove.
///
/// Grandfather is automatic: a fresh family is premium during its 30-day trial,
/// so the gate is exercised by forcing `plan = free` (`set_family_plan` also
/// clears the trial, so `is_premium()` turns false).
///
/// Port of `db-gate/Entrelares.IntegrationTests/CaregiverGateTests.cs`.
void caregiverGateTests(GateFixture fx) {
  Future<void> setPlan(int familyId, String plan) => fx.service.rpc<dynamic>(
      'set_family_plan', params: {'p_family_id': familyId, 'p_plan': plan});

  group('CaregiverGateTests', () {
    test('a free family is blocked at the third caregiver, and premium unblocks '
        'the very same invitation', () async {
      // The throwaway family starts with 2 active members and is premium via its
      // 30-day trial — force it to real free, which clears the trial too.
      final fam = await fx.createFamily('f37-free');
      await setPlan(fam.familyId, 'free');

      await expectRejected(
        () => GateFixture.createInvitation(
            fam.admin, fx.testEmail('f37-free-3rd'), fx.roleId('grandmother')),
        contains: 'Premium',
      );

      await setPlan(fam.familyId, 'premium');
      final token = await GateFixture.createInvitation(
          fam.admin, fx.testEmail('f37-free-3rd'), fx.roleId('grandmother'));
      expect(token, isNotEmpty);
    });

    test('a family still inside its trial allows the third caregiver', () async {
      // Grandfather grace: premium by trial, so no upgrade is needed.
      final fam = await fx.createFamily('f37-trial');

      final token = await GateFixture.createInvitation(
          fam.admin, fx.testEmail('f37-trial-3rd'), fx.roleId('grandmother'));
      expect(token, isNotEmpty);
    });
  });
}
