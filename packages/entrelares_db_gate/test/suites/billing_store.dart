import 'dart:convert';

import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import '_billing.dart';
import '_helpers.dart';

/// T-48 (redesigned, lote 5) — the DATABASE half of the store rail.
///
/// What is worth an integration test here is not the Play API (we cannot fake
/// Google in CI) but the rules that protect the money REGARDLESS of what the
/// client sends:
///   · `play` is a first-class gateway, and an invented one still is not;
///   · one purchase token funds ONE family — the unique index is what stops a
///     replayed receipt, so it is asserted against the real database;
///   · the store columns are readable by the family and writable by nobody but
///     service_role, like the rest of the row;
///   · `billing.store_enabled` is seeded PUBLIC and false, which is what keeps
///     the store build on the neutral T-38 note until the console side exists;
///   · the verify function refuses an anonymous caller, since it runs without
///     the platform gate and its own check is the whole door.
///
/// Port of `db-gate/Entrelares.IntegrationTests/BillingStoreTests.cs`.
void billingStoreTests(GateFixture fx) {
  /// Removes every row this suite could have left on a family.
  ///
  /// Called in a `finally` by each seeding test, and that is not tidiness: a
  /// seeded subscription that outlives its test POISONS the sibling suites,
  /// which assert on "this family has no subscription". That is exactly how the
  /// first CI run of the C# original broke the checkout suite.
  Future<void> clearSubscription(int familyId) async {
    await fx.service.from('subscriptions').delete().eq('family_id', familyId);
  }

  Future<Subscription> seedStoreSubscription(
      int familyId, String tag, String token) async {
    await fx.deleteSubscriptionSeed('sub_e2e_$tag');
    await clearSubscription(familyId);

    return Subscription.fromJson((await fx.service
            .from('subscriptions')
            .insert({
              'family_id': familyId,
              'gateway': 'play',
              'external_subscription_id': 'sub_e2e_$tag',
              'status': 'active',
              'cycle': 'monthly',
              'price_cents': 690,
              'billing_type': 'PLAY',
              'store_purchase_token': token,
              'store_product_id': 'premium_monthly',
              'current_period_end': DateTime.now()
                  .toUtc()
                  .add(const Duration(days: 30))
                  .toIso8601String(),
            })
            .select())
        .single);
  }

  group('BillingStoreTests', () {
    test('play is a valid gateway', () async {
      final token = 'tok_e2e_${fx.runId}_valid';
      try {
        final row = await seedStoreSubscription(fx.familyId, 'play_valid', token);
        expect(row.gateway, 'play');
        expect(row.storePurchaseToken, token);
      } finally {
        await clearSubscription(fx.familyId);
      }
    });

    test('an unknown gateway is refused', () async {
      // The CHECK is the guard that keeps a typo from creating a third, unowned
      // rail — one nothing reconciles and nobody watches.
      await clearSubscription(fx.familyBId);

      await expectRejected(
        () => fx.service.from('subscriptions').insert({
          'family_id': fx.familyBId,
          'gateway': 'stripe',
          'status': 'active',
          'cycle': 'monthly',
          'price_cents': 690,
        }),
        contains: 'gateway',
        caseInsensitive: true,
      );
    });

    test('a purchase token cannot fund two families', () async {
      // Without this, the same receipt replayed by a second family buys Premium
      // twice off one payment — and the CLIENT can never be the thing that
      // prevents it, which is why the assertion is against the real index.
      final token = 'tok_e2e_${fx.runId}_shared';
      try {
        await seedStoreSubscription(fx.familyId, 'play_first', token);
        await clearSubscription(fx.familyBId);

        await expectRejected(
          () => fx.service.from('subscriptions').insert({
            'family_id': fx.familyBId,
            'gateway': 'play',
            'status': 'active',
            'cycle': 'monthly',
            'price_cents': 690,
            'store_purchase_token': token,
            'store_product_id': 'premium_monthly',
          }),
          contains: 'duplicate',
          caseInsensitive: true,
        );
      } finally {
        await clearSubscription(fx.familyId);
        await clearSubscription(fx.familyBId);
      }
    });

    test('the family reads its store row and cannot write it', () async {
      final token = 'tok_e2e_${fx.runId}_rls';
      try {
        final row = await seedStoreSubscription(fx.familyId, 'play_rls', token);

        final visible = [
          for (final r in await fx.founder.from('subscriptions').select())
            Subscription.fromJson(r)
        ];
        expect(visible, hasLength(1));
        expect(visible.single.gateway, 'play');
        expect(visible.single.storeProductId, 'premium_monthly');

        // No authenticated write path exists — the store functions write with
        // the secret key, exactly like the Asaas webhook. The UPDATE fails
        // SILENTLY: with no UPDATE policy PostgREST matches 0 rows and returns
        // success, so asserting on a thrown exception proves nothing. The real
        // assertion is that the row is UNTOUCHED afterwards — the same trap the
        // webhook suite documents, and which the C# original walked straight
        // into on its first CI run.
        try {
          await fx.founder
              .from('subscriptions')
              .update({'cycle': 'annual', 'price_cents': 1}).eq('id', row.id);
        } catch (_) {
          // An error here is equally acceptable — it is the SILENT success that
          // must not be mistaken for a rule.
        }

        final after = await Billing(fx).reload(row.id);
        expect(after.cycle, 'monthly');
        expect(after.priceCents, 690);
      } finally {
        await clearSubscription(fx.familyId);
      }
    });

    test('the store switch is public and starts OFF', () async {
      // An offer the store cannot honour is worse than no offer, so `false` is
      // both the seed and the fail-closed default.
      final row = (await fx.founder
              .from('app_settings')
              .select('key, value')
              .eq('key', 'billing.store_enabled'))
          .single;
      expect(row['value'], 'false');
    });

    test('verify refuses an anonymous caller', () async {
      final response = await http.post(
        Uri.parse(Billing.functionUrl('billing-store-verify')),
        headers: {
          'apikey': TestEnv.anonKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'product_id': 'premium_monthly',
          'purchase_token': 'forged',
        }),
      );

      expect(response.statusCode, 401);
    });
  });
}
