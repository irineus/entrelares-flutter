import 'package:entrelares_db_contracts/entrelares_db_contracts.dart';
import 'package:entrelares_db_gate/entrelares_db_gate.dart';
import 'package:test/test.dart';

import '_billing.dart';
import '_helpers.dart';

/// F-32 — the freemium foundation, as DB rules:
///   · `set_family_plan` is service_role ONLY — no client can self-upgrade;
///   · new families default to free + a 30-day Premium trial, and `is_premium()`
///     is the single source of truth that mirrors it;
///   · the `premium_interest` waitlist is family-scoped (RLS) and idempotent.
///
/// Port of `db-gate/Entrelares.IntegrationTests/PremiumEntitlementTests.cs`.
void premiumEntitlementTests(GateFixture fx) {
  final billing = Billing(fx);

  group('PremiumEntitlementTests', () {
    test('an ADMIN cannot upgrade their own family', () async {
      // The RPC is granted to service_role alone: plan changes only ever come
      // from a trusted server context.
      await expectRejected(() => fx.founder.rpc<dynamic>('set_family_plan',
          params: {'p_family_id': fx.familyId, 'p_plan': 'premium'}));

      // Defensive: the plan really did not change.
      final family =
          Family.fromJson((await fx.founder.from('families').select()).single);
      expect(family.plan, 'free');
    });

    test('a non-admin member is likewise denied', () async {
      await expectRejected(() => fx.member.rpc<dynamic>('set_family_plan',
          params: {'p_family_id': fx.familyId, 'p_plan': 'premium'}));
    });

    test('a new family is free on trial, and the helper agrees', () async {
      final family =
          Family.fromJson((await fx.founder.from('families').select()).single);
      expect(family.plan, 'free');
      expect(family.trialEndsAt, isNotNull);
      final now = DateTime.now().toUtc();
      expect(family.trialEndsAt!.isAfter(now.add(const Duration(days: 25))), isTrue,
          reason: 'the trial should be ~30 days out');
      expect(family.trialEndsAt!.isBefore(now.add(const Duration(days: 35))), isTrue,
          reason: 'the trial should be ~30 days out');

      final isPremium = await fx.founder.rpc<dynamic>('is_premium');
      expect(isPremium.toString(), contains('true'));
    });

    test('the service role sets the plan, and the helper reflects it', () async {
      // Dropping to free CLEARS the trial, so `is_premium()` stays honest —
      // otherwise a downgraded family would keep premium until the trial it
      // never used ran out.
      final fam = await fx.createFamily('f32plan');

      await billing.setPlan(fam.familyId, 'free');
      expect(await billing.isPremium(fam.familyId), isFalse);

      await billing.setPlan(fam.familyId, 'premium');
      expect(await billing.isPremium(fam.familyId), isTrue);
    });

    test('premium interest is recorded per family and stays family-scoped',
        () async {
      await fx.member.rpc<dynamic>('register_premium_interest');

      final mine = await fx.founder.from('premium_interest').select();
      expect(mine, hasLength(1));
      expect(mine.single['family_id'], fx.familyId);

      // Idempotent per family — a second registration refreshes, not appends.
      await fx.founder.rpc<dynamic>('register_premium_interest');
      expect(await fx.founder.from('premium_interest').select(), hasLength(1));

      expect(await fx.founderB.from('premium_interest').select(), isEmpty);
    });
  });
}
