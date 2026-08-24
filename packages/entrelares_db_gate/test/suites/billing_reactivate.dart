import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_billing.dart';

/// F-42 (PR1) — "Reativar assinatura" with NO charge today.
///
/// Two halves, and the split is deliberate:
///
///   · **The Edge Function guard chain** (401 → 403 → billing disabled → row
///     state → paid time → stored customer → payment method). EVERY test here
///     stops at a guard that fires BEFORE the gateway is touched, so the suite
///     never creates a sandbox subscription. Because dev may run with
///     `billing.enabled` either way, the body assertions accept the "disabled"
///     refusal as an alternative to the specific one — which keeps them honest
///     in both states instead of silently passing for the wrong reason.
///
///   · **The grace cron's treatment of the new `scheduled` state**, which is
///     pure DB and therefore fully deterministic. This is the half that matters
///     most: a reactivated row is no longer `canceled`, so without the
///     migration's change a family whose scheduled invoice was never paid would
///     keep premium forever, for free.
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingReactivateTests.cs`.
void billingReactivateTests(GateFixture fx) {
  final billing = Billing(fx);
  const disabledRefusal = 'assinaturas ainda não estão abertas';

  Future<void> runGrace() =>
      fx.service.rpc<dynamic>('billing_grace_downgrade');

  group('BillingReactivateTests', () {
    // ── Guard chain ─────────────────────────────────────────────────────

    test('a reactivate with no session is rejected by the platform', () async {
      final (status, _) = await billing.checkout({'action': 'reactivate'}, null);
      expect(status, 401);
    });

    test('a non-admin cannot reactivate', () async {
      final token = fx.member.auth.currentSession!.accessToken;
      final (status, body) =
          await billing.checkout({'action': 'reactivate'}, token);
      expect(status, 403);
      expect(body, contains('administradores'));
    });

    test('an ACTIVE subscription has nothing to reactivate', () async {
      // Refusing here is what stops a second gateway subscription being created
      // for a family that is already paying.
      final fam = await fx.createFamily('f42ra');
      await billing.seed(fam.familyId, 'f42ra',
          status: 'active',
          periodEnd: DateTime.now().toUtc().add(const Duration(days: 20)),
          billingType: 'PIX',
          customerId: 'cus_e2e_f42ra');

      final token = fam.admin.auth.currentSession!.accessToken;
      final (status, body) =
          await billing.checkout({'action': 'reactivate'}, token);
      expect(status, 409);
      expect(body, contains('assinatura'));
    });

    test('canceled AND already lapsed is refused', () async {
      // There is no paid period left to schedule against, so the answer must be
      // "assine novamente" — never a subscription starting in the past.
      final fam = await fx.createFamily('f42rl');
      await billing.seed(fam.familyId, 'f42rl',
          status: 'canceled',
          periodEnd: DateTime.now().toUtc().subtract(const Duration(days: 3)),
          billingType: 'PIX',
          customerId: 'cus_e2e_f42rl');

      final token = fam.admin.auth.currentSession!.accessToken;
      final (status, body) =
          await billing.checkout({'action': 'reactivate'}, token);
      expect(status, 409);
      expect(
          body.contains('período já pago terminou') ||
              body.contains(disabledRefusal),
          isTrue,
          reason: 'unexpected refusal: $body');
    });

    test('a CARD family is refused, with Pix guidance', () async {
      // The asymmetry that defines the feature: a card family cannot be
      // rescheduled (there is no stored token) and must be TOLD so, with the
      // reassurance that paying now loses nothing.
      final fam = await fx.createFamily('f42rc');
      await billing.seed(fam.familyId, 'f42rc',
          status: 'canceled',
          periodEnd: DateTime.now().toUtc().add(const Duration(days: 15)),
          billingType: 'CREDIT_CARD',
          customerId: 'cus_e2e_f42rc');

      final token = fam.admin.auth.currentSession!.accessToken;
      final (status, body) =
          await billing.checkout({'action': 'reactivate'}, token);
      expect(status, 409);
      expect(body.contains('Pix e boleto') || body.contains(disabledRefusal),
          isTrue,
          reason: 'unexpected refusal: $body');
    });

    test('Pix with paid time but no stored customer degrades to a checkout',
        () async {
      // Nothing to bill against, so it must say so rather than erroring at the
      // gateway.
      final fam = await fx.createFamily('f42rn');
      await billing.seed(fam.familyId, 'f42rn',
          status: 'canceled',
          periodEnd: DateTime.now().toUtc().add(const Duration(days: 15)),
          billingType: 'PIX');

      final token = fam.admin.auth.currentSession!.accessToken;
      final (status, body) =
          await billing.checkout({'action': 'reactivate'}, token);
      expect(status, 409);
      expect(
          body.contains('cadastro de pagamento') ||
              body.contains(disabledRefusal),
          isTrue,
          reason: 'unexpected refusal: $body');
    });

    // ── The 'scheduled' state in the database ───────────────────────────

    test('the scheduled status and billing_type round-trip', () async {
      // The two schema changes everything else here depends on.
      final fam = await fx.createFamily('f42sc');
      final row = await billing.seed(fam.familyId, 'f42sc',
          status: 'scheduled',
          periodEnd: DateTime.now().toUtc().add(const Duration(days: 10)),
          billingType: 'PIX',
          customerId: 'cus_e2e_f42sc');

      expect(row.status, 'scheduled');
      expect(row.billingType, 'PIX');
    });

    test('a scheduled-but-unpaid subscription lapses to free', () async {
      // THE safety net. Without it, a missed PAYMENT_OVERDUE webhook would leave
      // the family premium forever, for free — because a reactivated row is no
      // longer `canceled` and the old sweep only looked at that.
      final fam = await fx.createFamily('f42sl');
      await billing.seed(fam.familyId, 'f42sl',
          status: 'scheduled',
          periodEnd: DateTime.now().toUtc().subtract(const Duration(days: 1)),
          billingType: 'PIX',
          customerId: 'cus_e2e_f42sl');
      await billing.setPlan(fam.familyId, 'premium');

      await runGrace();

      expect(await billing.planOf(fam.familyId), 'free');
    });

    test('a scheduled subscription with paid time left keeps premium',
        () async {
      // The other direction, which the safety net must NOT break: while the paid
      // period runs, `scheduled` is exactly what the family expects — premium,
      // no charge yet.
      final fam = await fx.createFamily('f42sk');
      await billing.seed(fam.familyId, 'f42sk',
          status: 'scheduled',
          periodEnd: DateTime.now().toUtc().add(const Duration(days: 12)),
          billingType: 'PIX',
          customerId: 'cus_e2e_f42sk');
      await billing.setPlan(fam.familyId, 'premium');

      await runGrace();

      expect(await billing.planOf(fam.familyId), 'premium');
    });
  });
}
