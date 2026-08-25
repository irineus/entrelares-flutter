import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_billing.dart';

/// T-39 (PR2) — the billing-checkout guard chain, in order: 401 without a user
/// JWT (`verify_jwt` stays ON for this function), 403 for a non-admin member,
/// 409 while `billing.enabled` is false.
///
/// The Asaas key is deliberately NOT needed: every test stops at a guard that
/// fires BEFORE the gateway is touched, so the suite never creates a sandbox
/// subscription and never leaves a payment link behind.
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingCheckoutTests.cs`.
void billingCheckoutTests(GateFixture fx) {
  final billing = Billing(fx);

  group('BillingCheckoutTests', () {
    test('a checkout with no session is rejected by the platform', () async {
      final (status, _) =
          await billing.checkout({'action': 'checkout', 'cycle': 'monthly'}, null);
      expect(status, 401);
    });

    test('a non-admin member cannot start a checkout', () async {
      // The payer is an admin — F-40/T-39 keep billing admin-only throughout.
      final token = fx.member.auth.currentSession!.accessToken;
      final (status, body) = await billing
          .checkout({'action': 'checkout', 'cycle': 'monthly'}, token);
      expect(status, 403);
      expect(body, contains('administradores'));
    });

    test('the guard chain refuses whether billing is open or already bought',
        () async {
      // Asserted against a family that ALREADY has an active subscription, so
      // the test is deterministic in both environments — flag off → "assinaturas
      // não abertas"; flag on → "família já tem uma assinatura" — and NEVER
      // reaches the gateway. The first version assumed the flag was off and
      // broke the moment dev enabled billing for the sandbox QA.
      final fam = await fx.createFamily('t39co');
      await billing.seed(fam.familyId, 't39co', status: 'active');

      final token = fam.admin.auth.currentSession!.accessToken;
      final (status, body) = await billing
          .checkout({'action': 'checkout', 'cycle': 'monthly'}, token);
      expect(status, 409);
      expect(body, contains('assinatura')); // both refusal texts mention it
    });

    test('a cancel with no subscription fails cleanly', () async {
      // Guard order puts `enabled` BEFORE the row lookup, so with billing
      // disabled this is a 409 — the assert accepts the disabled answer too,
      // which keeps it honest in both dev states rather than passing for the
      // wrong reason in one of them.
      final token = fx.founder.auth.currentSession!.accessToken;
      final (status, _) = await billing.checkout({'action': 'cancel'}, token);
      expect(status, anyOf(404, 409),
          reason: 'expected 404 (no subscription) or 409 (billing disabled), '
              'got $status');
    });
  });
}
