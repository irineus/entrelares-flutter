import 'package:entrelares_core/entrelares_core.dart';
import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// S-15/B-4 — the server half of the re-consent gate (`accept_current_policy`).
///
/// The legal review of 30/07/2026 made re-consent on a material policy change
/// obligatory, and the burden of proving consent is the controller's (LGPD art.
/// 8 §1). That is why these tests care less about the happy path than about what
/// the RPC REFUSES: a version the client made up, an unauthenticated caller, a
/// frozen profile — and why a refusal must never leave a half-written record.
///
/// Every test works on a THROWAWAY family: the shared fixture member is asserted
/// to have NULL consent columns by `consentAndRetentionTests`, and stamping it
/// here would break that test through the shared fixture.
///
/// Port of `db-gate/Entrelares.IntegrationTests/ReconsentGateTests.cs`.
void reconsentGateTests(GateFixture fx) {
  // A version that is certainly not the current one, used as the "behind"
  // starting state. The fixture signs its users up the way the register screen
  // really does (stamped with the CURRENT version), so each test builds the
  // precondition it needs instead of leaning on the fixture's incidental state
  // — which is also what makes these assertions about a TRANSITION.
  const staleVersion = '2020-01-01';

  group('ReconsentGateTests', () {
    test('an accept stamps the caller and nobody else', () async {
      final fam = await fx.createFamily('rcacc');

      // Put BOTH rows behind, so the isolation assertion at the end is real.
      await fx.service
          .from('profiles')
          .update({'consent_policy_version': staleVersion}).eq(
              'family_id', fam.familyId);

      await fam.member.rpc<dynamic>('accept_current_policy',
          params: {'p_version': PolicyVersions.current});

      final after = [
        for (final row in await fx.service
            .from('profiles')
            .select()
            .eq('family_id', fam.familyId))
          Member.fromJson(row)
      ];

      final member = after.firstWhere((p) => p.id == fam.memberProfile.id);
      expect(member.consentPolicyVersion, PolicyVersions.current);
      expect(member.consentAcceptedAt, isNotNull);

      // Consent is personal: accepting for myself must never stamp anyone else.
      // A record one member could create for another would be fabricated
      // evidence — the exact thing art. 8 §1 makes the controller answerable for.
      final admin = after.firstWhere((p) => p.id == fam.adminProfile.id);
      expect(admin.consentPolicyVersion, staleVersion);
    });

    test('an invented version is refused, and writes nothing', () async {
      final fam = await fx.createFamily('rcstale');

      await fx.service
          .from('profiles')
          .update({'consent_policy_version': staleVersion}).eq(
              'id', fam.memberProfile.id);

      await expectRejected(
        () => fam.member.rpc<dynamic>('accept_current_policy',
            params: {'p_version': staleVersion}),
        // The message is user-facing — the client turns it into "update the app".
        contains: 'desatualizada',
        caseInsensitive: true,
      );

      // A refused accept must leave NO trace: the row must still carry the OLD
      // version. Stamping the wrong one would be worse than no record at all.
      final member = Member.fromJson((await fx.service
              .from('profiles')
              .select()
              .eq('id', fam.memberProfile.id))
          .single);
      expect(member.consentPolicyVersion, staleVersion);
    });

    test('an anonymous caller is refused', () async {
      // EXECUTE is granted to `authenticated` only.
      final anon = fx.newAnonClient();
      try {
        await expectRejected(() => anon.rpc<dynamic>('accept_current_policy',
            params: {'p_version': PolicyVersions.current}));
      } finally {
        await anon.dispose();
      }
    });

    test('a frozen profile is refused', () async {
      // S-11: a member on the way out is frozen — the profile is immutable, so
      // the accept finds no active row and is refused rather than reviving it.
      final fam = await fx.createFamily('rcfrozen');

      await fx.elevate(fam.memberProfile);
      await fam.member.rpc<dynamic>('request_account_deletion');

      await expectRejected(
        () => fam.member.rpc<dynamic>('accept_current_policy',
            params: {'p_version': PolicyVersions.current}),
        contains: 'não encontrado',
        caseInsensitive: true,
      );
    });

    test('the code constant matches the server setting', () async {
      // The two-place checklist, pinned. A material change must bump BOTH
      // `PolicyVersions.current` and the `policy.current_version` setting
      // (migration). If only the code constant moves, the RPC starts refusing
      // EVERY accept in production — users are told to update an app that is
      // already current, and the gate blocks everyone with no way through. This
      // test is the red CI gate that replaces that live incident.
      final setting = await fx.service
          .from('app_settings')
          .select('value')
          .eq('key', 'policy.current_version');

      expect(setting, hasLength(1));
      expect(setting.single['value'], PolicyVersions.current);
    });

    test('the enforce-from constant matches the server setting', () async {
      // The OTHER half of the same checklist — the notice window. `enforce_from`
      // lives in settings so it can be adjusted without a deploy, and the CLIENT
      // mirrors it in `PolicyVersions.enforceFrom`. Nothing forces the two to
      // agree at runtime: the server would keep warning while the client already
      // blocks, or the reverse — a gate enforcing a date nobody published. Both
      // are silent, and both are exactly what the 15-day notice exists to make
      // impossible.
      final setting = await fx.service
          .from('app_settings')
          .select('value')
          .eq('key', 'policy.enforce_from');

      expect(setting, hasLength(1));
      expect(setting.single['value'], PolicyVersions.enforceFrom);
    });
  });
}
