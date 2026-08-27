import 'package:entrelares_core/entrelares_core.dart';
import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// F-57 — the deferred-profile branch of `handle_new_user` and the
/// `complete_oauth_onboarding` RPC (the founder path for a social-login
/// session).
///
/// An OAuth sign-up reaches the trigger with the provider's metadata, not our
/// forms' — no role, no family name, no invite token, no policy version. The
/// trigger must NOT raise (the exception would abort the auth.users INSERT and
/// the account would never exist): it defers, and the RPC creates family +
/// admin profile later, collecting role, family name and S-13 consent on the
/// onboarding screen.
void oauthOnboardingTests(GateFixture fx) {
  group('OauthOnboardingTests', () {
    test('an OAuth sign-up is deferred: auth user exists, NO profile', () async {
      final email = await fx.createOauthUser('oau-defer');

      // The user came into existence (createOauthUser returned an id) and the
      // trigger created nothing — the profile is the onboarding's job.
      final rows =
          await fx.service.from('profiles').select().eq('email', email);
      expect(rows, isEmpty,
          reason: 'handle_new_user must defer the profile when a sign-up '
              'carries none of our metadata');
    });

    test('a metadata-less password sign-up defers too — documented behaviour',
        () async {
      // The deferred branch keys on the ABSENCE of our metadata (the Admin
      // API cannot forge provider=google, and a rule this gate cannot
      // exercise would rot silently), so a password sign-up straight at the
      // GoTrue API — never possible through our forms, which always send the
      // metadata — now defers to onboarding instead of aborting the INSERT.
      // Nothing leans on the old refusal: a profile-less account is granted
      // nothing by RLS, and the onboarding RPCs are its only ways forward.
      final email = fx.testEmail('oau-pwd-norole');
      await fx.createBareUser(email);
      final rows =
          await fx.service.from('profiles').select().eq('email', email);
      expect(rows, isEmpty,
          reason: 'no profile until onboarding, same as an OAuth sign-up');
    });

    test('complete_oauth_onboarding creates family + admin profile, consent '
        'stamped', () async {
      final email = await fx.createOauthUser('oau-founder');
      final client = await fx.signIn(email);

      await client.rpc<dynamic>('complete_oauth_onboarding', params: {
        'p_full_name': 'E2E OAuth Founder',
        'p_role': 'father',
        'p_family_name': '${TestEnv.e2eFamilyPrefix}${fx.runId}-oauth',
        'p_policy_version': PolicyVersions.current,
      });

      final me = Member.fromJson(
          (await client.from('profiles').select().eq('email', email)).single);
      fx.trackFamily(me.familyId!);

      expect(me.isAdmin, isTrue, reason: 'the founder is the family admin');
      expect(me.colorSlot, 1, reason: 'founder takes slot 1 (S-11 QA)');
      expect(me.joinedViaInvite, isFalse);
      expect(me.consentPolicyVersion, PolicyVersions.current,
          reason: 'S-13: consent stamped at creation, like the register form');
      expect(me.consentAcceptedAt, isNotNull);

      // And it is a REAL family of its own, not an attachment to an existing
      // one.
      final family = (await fx.service
              .from('families')
              .select('name')
              .eq('id', me.familyId!))
          .single;
      expect(family['name'], '${TestEnv.e2eFamilyPrefix}${fx.runId}-oauth');

      // Calling again must refuse — the account is already attached, and a
      // double-tap must not create a second family.
      await expectRejected(
        () => client.rpc<dynamic>('complete_oauth_onboarding', params: {
          'p_full_name': 'E2E OAuth Founder',
          'p_role': 'father',
          'p_family_name': '${TestEnv.e2eFamilyPrefix}${fx.runId}-oauth2',
          'p_policy_version': PolicyVersions.current,
        }),
        contains: 'já está vinculada',
      );
    });

    test('a stale policy version is refused and nothing is created', () async {
      // S-15 posture: a stale client cannot stamp a consent it never displayed.
      final email = await fx.createOauthUser('oau-stale');
      final client = await fx.signIn(email);

      await expectRejected(
        () => client.rpc<dynamic>('complete_oauth_onboarding', params: {
          'p_full_name': 'E2E OAuth Stale',
          'p_role': 'father',
          'p_family_name': '${TestEnv.e2eFamilyPrefix}${fx.runId}-stale',
          'p_policy_version': '2020-01-01',
        }),
        contains: 'Versão da política desatualizada',
      );

      final rows =
          await fx.service.from('profiles').select().eq('email', email);
      expect(rows, isEmpty, reason: 'a refused onboarding must create nothing');
    });

    test('an unknown role is refused', () async {
      final email = await fx.createOauthUser('oau-badrole');
      final client = await fx.signIn(email);

      await expectRejected(
        () => client.rpc<dynamic>('complete_oauth_onboarding', params: {
          'p_full_name': 'E2E OAuth BadRole',
          'p_role': 'astronaut',
          'p_family_name': '${TestEnv.e2eFamilyPrefix}${fx.runId}-badrole',
          'p_policy_version': PolicyVersions.current,
        }),
        contains: 'Papel inválido',
      );

      final rows =
          await fx.service.from('profiles').select().eq('email', email);
      expect(rows, isEmpty);
    });

    test('anon cannot call it', () async {
      final anon = fx.newAnonClient();
      await expectRejected(
        () => anon.rpc<dynamic>('complete_oauth_onboarding', params: {
          'p_full_name': 'E2E Anon',
          'p_role': 'father',
          'p_family_name': 'Anon',
          'p_policy_version': PolicyVersions.current,
        }),
      );
    });

    test('a member with a profile cannot found a second family', () async {
      // The password member of family A calling the RPC: the "no profile yet"
      // condition is the whole authorization, so an ordinary account is
      // refused before anything else is looked at.
      await expectRejected(
        () => fx.member.rpc<dynamic>('complete_oauth_onboarding', params: {
          'p_full_name': 'E2E Member',
          'p_role': 'father',
          'p_family_name': '${TestEnv.e2eFamilyPrefix}${fx.runId}-dupe',
          'p_policy_version': PolicyVersions.current,
        }),
        contains: 'já está vinculada',
      );
    });
  });
}
