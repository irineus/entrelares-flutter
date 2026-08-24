import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_helpers.dart';

/// S-13 — LGPD accountability:
///   · demonstrable consent: `handle_new_user` stamps `consent_accepted_at` +
///     `consent_policy_version` from the sign-up metadata;
///   · profiles created WITHOUT the `policy_version` metadata keep NULL consent
///     columns — legacy semantics, because recording must never be fabricated;
///   · retention: `purge_old_notifications` deletes READ notifications older
///     than 6 months and nothing else.
///
/// Port of `db-gate/Entrelares.IntegrationTests/ConsentAndRetentionTests.cs`.
void consentAndRetentionTests(GateFixture fx) {
  group('ConsentAndRetentionTests', () {
    test('a sign-up carrying policy_version records the consent', () async {
      final fam = await fx.createFamily('consent');
      final admin = AdminApi();
      try {
        final email = fx.testEmail('consent-3rd');
        final token =
            await GateFixture.createInvitation(fam.admin, email, fx.roleId('aunt'));
        await admin.createConfirmedUser(email, fx.password, {
          'full_name': 'E2E Consent Third',
          'invite_token': token,
          'policy_version': '2026-07-21',
        });

        final joined = Member.fromJson(
            (await fx.service.from('profiles').select().eq('email', email))
                .single);
        expect(joined.consentAcceptedAt, isNotNull);
        expect(joined.consentPolicyVersion, '2026-07-21');
      } finally {
        admin.close();
      }
    });

    test('a sign-up without policy_version leaves the consent columns null',
        () async {
      // The invitee is created WITHOUT policy_version on purpose. This used to
      // ride on the throwaway family, which sent no version either — but S-15's
      // re-consent gate blocks NULL-consent profiles once its notice window has
      // elapsed, so the fixture now signs its users up the way the register
      // screen really does (with the version). The legacy shape therefore needs
      // an explicit sign-up here, which is also more honest: this test is about
      // the metadata-less path, not about whatever the fixture happens to do.
      final fam = await fx.createFamily('noconsent');
      final admin = AdminApi();
      try {
        final email = fx.testEmail('noconsent-3rd');
        final token =
            await GateFixture.createInvitation(fam.admin, email, fx.roleId('aunt'));
        await admin.createConfirmedUser(email, fx.password, {
          'full_name': 'E2E No Consent',
          'invite_token': token,
          // policy_version deliberately absent
        });

        final joined = Member.fromJson(
            (await fx.service.from('profiles').select().eq('email', email))
                .single);
        expect(joined.consentAcceptedAt, isNull);
        expect(joined.consentPolicyVersion, isNull);
      } finally {
        admin.close();
      }
    });

    test('the retention purge removes only what is READ and OLD', () async {
      final readOld = 'e2e-ret-read-old-${uniqueMarker()}';
      final readRecent = 'e2e-ret-read-recent-${uniqueMarker()}';
      final unreadOld = 'e2e-ret-unread-old-${uniqueMarker()}';
      final now = DateTime.now().toUtc();

      for (final seed in [
        (readOld, true, now.subtract(const Duration(days: 210))),
        (readRecent, true, now.subtract(const Duration(days: 30))),
        (unreadOld, false, now.subtract(const Duration(days: 210))),
      ]) {
        await fx.service.from('notifications').insert({
          'recipient_profile_id': fx.memberProfile.id,
          'type': 'swap_requested',
          'title': 'E2E retenção',
          'message': seed.$1,
          'is_read': seed.$2,
          'created_at': seed.$3.toIso8601String(),
        });
      }

      await fx.service.rpc<dynamic>('purge_old_notifications');

      final remaining = (await fx.service
              .from('notifications')
              .select('message')
              .eq('recipient_profile_id', fx.memberProfile.id))
          .map((n) => n['message'])
          .toList();
      expect(remaining, isNot(contains(readOld))); // purged
      expect(remaining, contains(readRecent)); // kept (recent)
      expect(remaining, contains(unreadOld)); // kept (unread)
    });
  });
}
