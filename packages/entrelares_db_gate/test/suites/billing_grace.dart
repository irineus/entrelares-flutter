import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_billing.dart';
import '_helpers.dart';

/// T-39 (PR3) — the grace-period downgrade cron (`billing_grace_downgrade`):
///   · a canceled subscription whose paid period lapsed → plan free;
///   · an overdue one past `billing.grace_days` → plan free, with the status
///     STAYING `overdue`, so a late payment can still reactivate via webhook;
///   · paid time remaining → untouched;
///   · the downgrade never deletes data, and it is service_role only.
///
/// Plus the additive activation rules (webhook, armed by the shared token):
/// re-subscribing with paid time left EXTENDS from the old period end, and a
/// first payment DURING the trial extends from the trial end (F-46).
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingGraceTests.cs`.
void billingGraceTests(GateFixture fx) {
  final billing = Billing(fx);

  Future<void> runGrace() =>
      fx.service.rpc<dynamic>('billing_grace_downgrade');

  DateTime todayUtc() {
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day);
  }

  group('BillingGraceTests', () {
    test('a lapsed canceled subscription downgrades to free, keeping the data',
        () async {
      final fam = await fx.createFamily('t39gr1');
      await billing.seed(fam.familyId, 't39gr1',
          status: 'canceled',
          periodEnd:
              DateTime.now().toUtc().subtract(const Duration(days: 1)));
      await billing.setPlan(fam.familyId, 'premium');

      await runGrace();

      expect(await billing.planOf(fam.familyId), 'free');
      // A downgrade is a loss of FEATURES, never of data — the member still
      // reads their family normally.
      expect(await fam.member.from('families').select(), hasLength(1));
      // Idempotent: a second sweep changes nothing (already free → filtered).
      await runGrace();
      expect(await billing.planOf(fam.familyId), 'free');
    });

    test('overdue past the grace window downgrades but STAYS overdue',
        () async {
      // The status is what lets a late payment still reactivate through the
      // webhook — flipping it to canceled would strand the payer.
      final fam = await fx.createFamily('t39gr2');
      await billing.seed(fam.familyId, 't39gr2',
          status: 'overdue',
          overdueSince:
              DateTime.now().toUtc().subtract(const Duration(days: 8)));
      await billing.setPlan(fam.familyId, 'premium');

      await runGrace();

      expect(await billing.planOf(fam.familyId), 'free');
      expect((await billing.subscriptionOf(fam)).status, 'overdue');
    });

    test('paid time remaining is left alone', () async {
      final fam = await fx.createFamily('t39gr3');
      await billing.seed(fam.familyId, 't39gr3',
          status: 'canceled',
          periodEnd: DateTime.now().toUtc().add(const Duration(days: 10)));
      await billing.setPlan(fam.familyId, 'premium');

      await runGrace();

      expect(await billing.planOf(fam.familyId), 'premium');
    });

    test('the sweep is denied to clients', () async {
      await expectRejected(
          () => fx.founder.rpc<dynamic>('billing_grace_downgrade'));
    });

    // ── Additive renewal (webhook, armed by the shared token) ───────────────

    test('a renewal with paid time left extends from the OLD period end',
        () async {
      final token = Billing.webhookToken;
      if (token == null) return; // armed by E2E_ASAAS_WEBHOOK_TOKEN

      final fam = await fx.createFamily('t39add');
      // Post-trial family: without this, the fresh family's default 30-day
      // trial would win the max and shift the expected base (F-46).
      await billing.setTrial(fam.familyId, null);
      final sub = await billing.seed(fam.familyId, 't39add',
          status: 'canceled',
          periodEnd: todayUtc().add(const Duration(days: 15)));

      final (status, body) = await billing.webhook({
        'id': 'evt_e2e_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_RECEIVED',
        'payment': {
          'id': 'pay_e2e_add',
          'subscription': sub.externalSubscriptionId,
          'dueDate': isoDate(todayUtc()),
        },
      }, token);
      expect(status, 200, reason: body);

      final updated = await billing.subscriptionOf(fam);
      expect(updated.status, 'active');
      // Base = the OLD period end (15 days out), not today: +1 month on top.
      final expected =
          DateTime.utc(todayUtc().year, todayUtc().month + 1, todayUtc().day + 15);
      expect(updated.currentPeriodEnd, isNotNull);
      expect(updated.currentPeriodEnd!.difference(expected).inHours.abs(),
          lessThanOrEqualTo(24),
          reason: 'period end ${updated.currentPeriodEnd} should extend from '
              'the old end (~$expected)');
    });

    test('a first payment DURING the trial extends from the trial end',
        () async {
      // F-46: the trial is a first payment of R$ 0, so paying during it starts
      // the paid cycle at the trial END — the remaining days are added, never
      // forfeited — and the consumed trial is cleared.
      final token = Billing.webhookToken;
      if (token == null) return; // armed by E2E_ASAAS_WEBHOOK_TOKEN

      final fam = await fx.createFamily('t46tr');
      final trialEnd = todayUtc().add(const Duration(days: 20));
      await billing.setTrial(fam.familyId, trialEnd);
      // A first payment: the checkout row has no paid period yet.
      final sub = await billing.seed(fam.familyId, 't46tr', status: 'pending');

      final (status, body) = await billing.webhook({
        'id': 'evt_e2e_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_RECEIVED',
        'payment': {
          'id': 'pay_e2e_trial',
          'subscription': sub.externalSubscriptionId,
          'dueDate': isoDate(todayUtc()),
        },
      }, token);
      expect(status, 200, reason: body);

      final updated = await billing.subscriptionOf(fam);
      expect(updated.status, 'active');
      final expected =
          DateTime.utc(trialEnd.year, trialEnd.month + 1, trialEnd.day);
      expect(updated.currentPeriodEnd, isNotNull);
      expect(updated.currentPeriodEnd!.difference(expected).inHours.abs(),
          lessThanOrEqualTo(24),
          reason: 'period end ${updated.currentPeriodEnd} should extend from '
              'the trial end (~$expected)');

      // The consumed trial is cleared — the paid period is now the single
      // source of the entitlement window, and the plan carries the premium.
      expect(await billing.planOf(fam.familyId), 'premium');
      final family = await fx.service
          .from('families')
          .select('trial_ends_at')
          .eq('id', fam.familyId);
      expect(family.single['trial_ends_at'], isNull);
    });
  });
}
