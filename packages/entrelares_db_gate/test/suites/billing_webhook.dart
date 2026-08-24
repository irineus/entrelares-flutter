import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_billing.dart';
import '_helpers.dart';

/// T-39 (PR1) — the billing bookkeeping DB rules plus the Asaas webhook
/// contract:
///   · `subscriptions`: family-scoped SELECT, and NO authenticated write path;
///   · `billing_events`: invisible to authenticated callers (service_role only)
///     — the ledger holds raw gateway payloads;
///   · the `billing.*` settings are seeded, and only the public ones are
///     readable by clients;
///   · the webhook rejects a call without the shared token;
///   · the happy paths (confirm → premium, refund → free, idempotent
///     redelivery) run only when the shared token is available.
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingWebhookTests.cs`.
void billingWebhookTests(GateFixture fx) {
  final billing = Billing(fx);

  group('BillingWebhookTests', () {
    // ── DB rules ─────────────────────────────────────────────────────────

    test('subscriptions are family-scoped and read-only for clients', () async {
      final fam = await fx.createFamily('t39rls');
      await billing.seed(fam.familyId, 't39rls');

      final mine = await billing.subscriptionOf(fam);
      expect(mine.status, 'pending');
      expect(mine.priceCents, 1490);

      // The MAIN family sees none of the throwaway family's billing state.
      expect(await fx.founder.from('subscriptions').select(), isEmpty);

      // No authenticated write path. INSERT violates RLS LOUDLY (42501)…
      await expectRejected(() => fx.founder.from('subscriptions').insert({
            'family_id': fx.familyId,
            'cycle': 'monthly',
            'price_cents': 1,
          }));

      // …while UPDATE fails SILENTLY: with no UPDATE policy PostgREST matches 0
      // rows and answers success. It bit this suite on its first CI run, which
      // is why the assertion is that the row is UNTOUCHED.
      try {
        await fam.member
            .from('subscriptions')
            .update({'status': 'active'}).eq('id', mine.id);
      } catch (_) {
        // An error here is equally acceptable.
      }
      expect((await billing.subscriptionOf(fam)).status, 'pending');
    });

    test('the event ledger is invisible to clients', () async {
      // An authenticated client gets an empty result (RLS), never a gateway
      // payload.
      expect(await fx.founder.from('billing_events').select(), isEmpty);
    });

    test('only the PUBLIC billing settings are readable', () async {
      final settings = {
        for (final row in await fx.founder
            .from('app_settings')
            .select('key, value')
            .eq('category', 'billing'))
          row['key'] as String: row['value'] as String
      };

      expect(settings.keys, contains('billing.enabled'));
      expect(settings.keys, contains('billing.price_monthly_cents'));
      expect(settings.keys, contains('billing.price_annual_cents'));
      // U-22 joined `grace_days` to the public set: the overdue panel shows the
      // real grace deadline, while ENFORCEMENT stays in the server cron.
      expect(settings.keys, contains('billing.grace_days'));

      // F-48: the promotional launch price is 549, not 490 — the gateway
      // refuses Pix/boleto charges under R$ 5,00, which the QA round found.
      expect(settings['billing.price_monthly_cents'], '549');
      expect(settings['billing.price_annual_cents'], '5490');
      expect(settings['billing.grace_days'], '7');
    });

    // ── Webhook contract ─────────────────────────────────────────────────

    test('a call without the shared token is rejected', () async {
      // The webhook is not an open door: anyone who found the URL could
      // otherwise grant themselves Premium.
      final (status, _) = await billing.webhook({
        'id': 'evt_e2e_unauth_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_CONFIRMED',
      }, null);

      expect(status, 401);
    });

    test('a confirmed payment activates the plan, idempotently', () async {
      final token = Billing.webhookToken;
      if (token == null) return; // armed by E2E_ASAAS_WEBHOOK_TOKEN

      final fam = await fx.createFamily('t39ok');
      final sub = await billing.seed(fam.familyId, 't39ok');
      await billing.setPlan(fam.familyId, 'free');

      final now = DateTime.now().toUtc();
      final payload = {
        'id': 'evt_e2e_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_CONFIRMED',
        'payment': {
          'id': 'pay_e2e_1',
          'subscription': sub.externalSubscriptionId,
          'value': 14.90,
          'dueDate': isoDate(DateTime.utc(now.year, now.month, now.day)),
        },
      };

      final (first, firstBody) = await billing.webhook(payload, token);
      expect(first, 200, reason: firstBody);

      final updated = await billing.subscriptionOf(fam);
      expect(updated.status, 'active');
      expect(updated.currentPeriodEnd, isNotNull);
      expect(await billing.isPremium(fam.familyId), isTrue);

      // Force the plan down, then REDELIVER the same event id: the ledger must
      // swallow it. A gateway retries, and a retry that re-activates is a
      // subscription nobody paid for twice.
      await billing.setPlan(fam.familyId, 'free');
      final (redelivery, redeliveryBody) = await billing.webhook(payload, token);
      expect(redelivery, 200, reason: redeliveryBody);
      expect(await billing.isPremium(fam.familyId), isFalse);
    });

    test('a refund downgrades to free, keeping the data', () async {
      final token = Billing.webhookToken;
      if (token == null) return; // armed by E2E_ASAAS_WEBHOOK_TOKEN

      final fam = await fx.createFamily('t39ref');
      final sub = await billing.seed(fam.familyId, 't39ref');
      final now = DateTime.now().toUtc();

      await billing.webhook({
        'id': 'evt_e2e_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_CONFIRMED',
        'payment': {
          'id': 'pay_e2e_2',
          'subscription': sub.externalSubscriptionId,
          'dueDate': isoDate(DateTime.utc(now.year, now.month, now.day)),
        },
      }, token);

      final (status, body) = await billing.webhook({
        'id': 'evt_e2e_${billing.uniqueEventSuffix()}',
        'event': 'PAYMENT_REFUNDED',
        'payment': {
          'id': 'pay_e2e_2',
          'subscription': sub.externalSubscriptionId,
        },
      }, token);
      expect(status, 200, reason: body);

      expect((await billing.subscriptionOf(fam)).status, 'canceled');
      expect(await billing.isPremium(fam.familyId), isFalse);

      // A downgrade never deletes anything: the member still reads their family.
      expect(await fam.member.from('families').select(), hasLength(1));
    });
  });
}
