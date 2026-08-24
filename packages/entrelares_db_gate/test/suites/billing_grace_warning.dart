import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_billing.dart';
import '_helpers.dart';

/// S-15/B-3 — `billing_grace_warnings_due()`.
///
/// PR3a published *"Avisaremos por e-mail antes da indisponibilidade"* in the
/// Terms. Nothing implemented it: the grace downgrade flipped the plan in
/// silence. These tests are what make that sentence true, and they care most
/// about the two ways a warning goes wrong — never arriving, or arriving over
/// and over.
///
/// Defaults assumed: `billing.grace_days = 7`, `billing.grace_warning_days = 2`,
/// so the window is `[overdue_since + 5d, overdue_since + 7d)`.
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingGraceWarningTests.cs`.
void billingGraceWarningTests(GateFixture fx) {
  final billing = Billing(fx);

  Future<int> seedOverdue(int familyId, String tag, int overdueDaysAgo) async {
    final sub = await billing.seed(familyId, tag,
        status: 'overdue',
        overdueSince:
            DateTime.now().toUtc().subtract(Duration(days: overdueDaysAgo)));
    await billing.setPlan(familyId, 'premium');
    return sub.id;
  }

  Future<void> warn() =>
      fx.service.rpc<dynamic>('billing_grace_warnings_due');

  Future<List<Map<String, dynamic>>> billingNotices(int profileId) async =>
      (await fx.service
              .from('notifications')
              .select()
              .eq('recipient_profile_id', profileId)
              .eq('type', 'billing'))
          .cast<Map<String, dynamic>>();

  group('BillingGraceWarningTests', () {
    test('inside the window the admin is warned, and the marker is stamped',
        () async {
      final fam = await fx.createFamily('gw1');
      final subId = await seedOverdue(fam.familyId, 'gw1', 6);

      await warn();

      expect((await billing.reload(subId)).graceWarningSentAt, isNotNull);

      // The IN-APP notice is the reliable channel — written by the RPC in the
      // same transaction as the marker, so it survives a Resend outage. The
      // e-mail is the best-effort twin.
      final notices = await billingNotices(fam.adminProfile.id);
      expect(notices, hasLength(1));
      expect(notices.single['message'], contains('Plano Gratuito'));
    });

    test('a non-admin member is not warned', () async {
      // Someone who cannot reach the checkout must not get an alarm they have
      // no way to answer.
      final fam = await fx.createFamily('gw2');
      await seedOverdue(fam.familyId, 'gw2', 6);

      await warn();

      expect(await billingNotices(fam.memberProfile.id), isEmpty);
    });

    test('a second run does not warn again', () async {
      // The cron runs daily and the window is two days wide, so without the
      // marker the same family would be warned every run.
      final fam = await fx.createFamily('gw3');
      await seedOverdue(fam.familyId, 'gw3', 6);

      await warn();
      await warn();
      await warn();

      expect(await billingNotices(fam.adminProfile.id), hasLength(1));
    });

    test('before the window, nothing is sent', () async {
      // Warning on day 1 of a 7-day grace would be alarmist, and it would burn
      // the single notice long before it is useful.
      final fam = await fx.createFamily('gw4');
      final subId = await seedOverdue(fam.familyId, 'gw4', 1);

      await warn();

      expect((await billing.reload(subId)).graceWarningSentAt, isNull);
      expect(await billingNotices(fam.adminProfile.id), isEmpty);
    });

    test('after the grace expired, nothing is sent', () async {
      // Past the downgrade there is nothing to warn ABOUT — the access is
      // already gone, and "avisaremos ANTES" would be a lie.
      final fam = await fx.createFamily('gw5');
      final subId = await seedOverdue(fam.familyId, 'gw5', 9);

      await warn();

      expect((await billing.reload(subId)).graceWarningSentAt, isNull);
      expect(await billingNotices(fam.adminProfile.id), isEmpty);
    });

    test('a NEW overdue cycle re-arms the warning', () async {
      // Without the reset trigger, a family warned once would go silent for
      // good: it pays, falls overdue months later, and the stale marker
      // suppresses the second warning.
      final fam = await fx.createFamily('gw6');
      final subId = await seedOverdue(fam.familyId, 'gw6', 6);

      await warn();
      expect((await billing.reload(subId)).graceWarningSentAt, isNotNull);

      // The webhook stamping a fresh `overdue_since` is what starts a new cycle.
      await fx.service.from('subscriptions').update({
        'overdue_since': DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 6, minutes: 1))
            .toIso8601String(),
      }).eq('id', subId);

      expect((await billing.reload(subId)).graceWarningSentAt, isNull);

      await warn();
      expect(await billingNotices(fam.adminProfile.id), hasLength(2));
    });

    test('the warning sweep is refused for an authenticated caller', () async {
      // It writes notifications for OTHER people — service_role only.
      final fam = await fx.createFamily('gw7');

      await expectRejected(
          () => fam.member.rpc<dynamic>('billing_grace_warnings_due'));
    });
  });
}
