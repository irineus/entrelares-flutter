import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_billing.dart';

/// F-48 (block 3) — Pix avulso: a single NON-RECURRING charge. The webhook half
/// is what the database and functions own, and what these tests pin:
///   · a payment WITHOUT a subscription id that matches a `single_charge` row
///     (`externalReference` = `family:<id>`) settles it as
///     canceled-with-paid-time: premium until +1 cycle, no recurrence, the
///     billing type stored;
///   · a SECOND avulso payment is ADDITIVE, extending from the paid end;
///   · `PAYMENT_OVERDUE` never touches an avulso row — an unpaid single charge
///     is an abandoned checkout, not a failed renewal, and putting a family into
///     dunning for it would be a lie on their screen.
///
/// Like the other webhook suites, the happy paths are armed by the shared token
/// and early-return without it.
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingAvulsoTests.cs`.
void billingAvulsoTests(GateFixture fx) {
  final billing = Billing(fx);

  /// An avulso row as the checkout creates it: pending, `single_charge`, and NO
  /// gateway subscription id — a DETACHED charge never has one, which is why
  /// this seed does not go through [Billing.seed] and needs no delete-first
  /// (the family is fresh per test and the row carries no fixed unique key).
  Future<Subscription> seedAvulso(int familyId) async =>
      Subscription.fromJson((await fx.service
              .from('subscriptions')
              .insert({
                'family_id': familyId,
                'cycle': 'monthly',
                'price_cents': 490,
                'single_charge': true,
              })
              .select())
          .single);

  DateTime todayUtc() {
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day);
  }

  Map<String, dynamic> paymentEvent(int familyId, {String? billingType}) => {
        'id': 'evt_e2e_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_RECEIVED',
        'payment': {
          'id': 'pay_e2e_${billing.uniqueEventSuffix()}',
          'value': 4.90,
          'billingType': billingType,
          'externalReference': 'family:$familyId',
          'dueDate': isoDate(todayUtc()),
        },
      };

  group('BillingAvulsoTests', () {
    test('an avulso payment settles as canceled with a paid period', () async {
      final token = Billing.webhookToken;
      if (token == null) return; // armed by E2E_ASAAS_WEBHOOK_TOKEN

      final fam = await fx.createFamily('f48av1');
      // F-46: the webhook folds a STILL-RUNNING trial into the paid period,
      // which would blur the +1-month assertion. Clearing it makes the period
      // maths exact; the trial interplay itself is the recurring path's business.
      await billing.setTrial(fam.familyId, null);
      await seedAvulso(fam.familyId);

      final (status, body) =
          await billing.webhook(paymentEvent(fam.familyId, billingType: 'PIX'), token);
      expect(status, 200, reason: body);

      final updated = await billing.subscriptionOf(fam);
      expect(updated.status, 'canceled');
      expect(updated.singleCharge, isTrue);
      expect(updated.canceledAt, isNotNull);
      expect(updated.billingType, 'PIX');
      expect(updated.currentPeriodEnd, isNotNull);

      final due = todayUtc();
      final expected = DateTime.utc(due.year, due.month + 1, due.day);
      expect(updated.currentPeriodEnd!.difference(expected).inHours.abs(),
          lessThan(48),
          reason: 'period end ${updated.currentPeriodEnd} '
              'is not ~1 month after $due');

      expect(await billing.isPremium(fam.familyId), isTrue);
    });

    test('a SECOND avulso payment extends from the paid end', () async {
      // Additive: the new cycle counts from the end of the already-paid one,
      // never from the payment date — and the row stays non-recurring.
      final token = Billing.webhookToken;
      if (token == null) return; // armed by E2E_ASAAS_WEBHOOK_TOKEN

      final fam = await fx.createFamily('f48av2');
      await billing.setTrial(fam.familyId, null);
      await seedAvulso(fam.familyId);

      for (var i = 0; i < 2; i++) {
        final (status, body) = await billing
            .webhook(paymentEvent(fam.familyId, billingType: 'PIX'), token);
        expect(status, 200, reason: body);
      }

      final updated = await billing.subscriptionOf(fam);
      expect(updated.status, 'canceled');
      final due = todayUtc();
      final expected = DateTime.utc(due.year, due.month + 2, due.day);
      expect(updated.currentPeriodEnd!.difference(expected).inHours.abs(),
          lessThan(72),
          reason: 'period end ${updated.currentPeriodEnd} is not ~2 months '
              'after $due — the second payment was not additive');
    });

    test('PAYMENT_OVERDUE never touches an avulso row', () async {
      final token = Billing.webhookToken;
      if (token == null) return; // armed by E2E_ASAAS_WEBHOOK_TOKEN

      final fam = await fx.createFamily('f48av3');
      await seedAvulso(fam.familyId);

      final (status, body) = await billing.webhook({
        'id': 'evt_e2e_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_OVERDUE',
        'payment': {
          'id': 'pay_e2e_${billing.uniqueEventSuffix()}',
          'externalReference': 'family:${fam.familyId}',
        },
      }, token);
      expect(status, 200, reason: body);

      final updated = await billing.subscriptionOf(fam);
      expect(updated.status, 'pending');
      expect(updated.overdueSince, isNull);
    });
  });
}
