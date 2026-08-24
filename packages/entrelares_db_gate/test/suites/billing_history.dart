import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:supabase/supabase.dart';
import 'package:test/test.dart';

import '_billing.dart';
import '_helpers.dart';

/// F-43 — the payment-history RPC (`get_billing_history`):
///   · family ADMINS get a sanitized, family-scoped timeline, never the raw
///     ledger payloads;
///   · `CONFIRMED` + `RECEIVED` for the same gateway payment collapse to ONE
///     row — a payer who saw one charge must read one line;
///   · non-admins are refused by the DB itself;
///   · another family's events never leak.
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingHistoryTests.cs`.
void billingHistoryTests(GateFixture fx) {
  final billing = Billing(fx);

  Future<List<Map<String, dynamic>>> historyAs(SupabaseClient caller) async {
    final result = await caller.rpc<dynamic>('get_billing_history');
    return (result as List).cast<Map<String, dynamic>>();
  }

  group('BillingHistoryTests', () {
    test('an admin sees a sanitized timeline, with the duplicate collapsed',
        () async {
      final fam = await fx.createFamily('f43hist');

      await billing.seedEvent(fam.familyId, 'PAYMENT_CONFIRMED',
          paymentId: 'pay_h1',
          value: 14.90,
          billingType: 'PIX',
          invoiceUrl: 'https://sandbox.asaas.com/i/h1');
      await billing.seedEvent(fam.familyId, 'PAYMENT_RECEIVED',
          paymentId: 'pay_h1',
          value: 14.90,
          billingType: 'PIX',
          invoiceUrl: 'https://sandbox.asaas.com/i/h1');
      await billing.seedEvent(fam.familyId, 'PAYMENT_REFUNDED',
          paymentId: 'pay_h1', value: 14.90, billingType: 'PIX');
      await billing.seedEvent(fam.familyId, 'GRACE_DOWNGRADE');
      // Internal/ops events must never surface — the timeline is for a payer,
      // not for us.
      await billing.seedEvent(fam.familyId, 'CHECKOUT_ERROR');
      await billing.seedEvent(fam.familyId, 'PAYMENT_CREATED',
          paymentId: 'pay_h2');

      final rows = await historyAs(fam.admin);
      final categories = [for (final r in rows) r['category']];

      expect(rows, hasLength(3)); // payment (deduped) + refund + downgrade
      expect(categories.where((c) => c == 'payment'), hasLength(1));
      expect(categories, contains('refund'));
      expect(categories, contains('downgraded'));
      expect(categories, isNot(contains(null)));

      final payment = rows.firstWhere((r) => r['category'] == 'payment');
      expect((payment['amount'] as num).toDouble(), closeTo(14.90, 0.001));
      expect(payment['billing_type'], 'PIX');
      expect(payment['invoice_url'], 'https://sandbox.asaas.com/i/h1');
    });

    test('a non-admin is refused by the database itself', () async {
      final fam = await fx.createFamily('f43deny');
      await expectRejected(
          () => fam.member.rpc<dynamic>('get_billing_history'));
    });

    test("another family's events never leak", () async {
      final fam = await fx.createFamily('f43iso');
      await billing.seedEvent(fam.familyId, 'PAYMENT_CONFIRMED',
          paymentId: 'pay_iso', value: 14.90);

      expect(await historyAs(fx.founder), isEmpty);
    });
  });
}
