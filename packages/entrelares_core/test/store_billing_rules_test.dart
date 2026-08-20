import 'package:entrelares_core/entrelares_core.dart';
import 'package:test/test.dart';

/// T-48 — the store rail's pure rules. Two of these are worth more than they
/// look: the product ids are a Play Console FACT (renaming one orphans the
/// purchases made against it), and the state machine's default is the neutral
/// note, which is what keeps the Play listing compliant when anything at all
/// goes wrong.
void main() {
  group('products', () {
    test('the ids are pinned — renaming one orphans real purchases', () {
      expect(storeProductMonthly, 'premium_monthly');
      expect(storeProductAnnual, 'premium_annual');
    });

    test('a cycle maps to its product, and an unknown one to the cheaper', () {
      expect(storeProductForCycle('monthly'), storeProductMonthly);
      expect(storeProductForCycle('annual'), storeProductAnnual);
      // A bad value must never charge MORE than the family expected.
      expect(storeProductForCycle(null), storeProductMonthly);
      expect(storeProductForCycle('weekly'), storeProductMonthly);
    });

    test('an unrecognised product id is never read as an offer', () {
      expect(cycleForStoreProduct(storeProductMonthly), 'monthly');
      expect(cycleForStoreProduct(storeProductAnnual), 'annual');
      expect(cycleForStoreProduct('premium_lifetime'), isNull);
      expect(cycleForStoreProduct(null), isNull);
    });
  });

  group('manage link', () {
    test('points at the subscription when we know which one', () {
      expect(
        playManageSubscriptionUrl(
            packageName: 'com.entrelares.app', productId: storeProductAnnual),
        'https://play.google.com/store/account/subscriptions'
            '?sku=premium_annual&package=com.entrelares.app',
      );
    });

    test('falls back to the subscriptions list with no product', () {
      expect(
        playManageSubscriptionUrl(packageName: 'com.entrelares.app'),
        'https://play.google.com/store/account/subscriptions',
      );
    });
  });

  group('store offer state machine', () {
    StoreOffer offer({
      bool enabled = true,
      bool available = true,
      bool products = true,
      bool pending = false,
      bool premium = false,
    }) =>
        computeStoreOffer(
          storeBillingEnabled: enabled,
          storeAvailable: available,
          hasProducts: products,
          purchasePending: pending,
          premiumThroughStore: premium,
        );

    test('the switch off is the neutral note, whatever else is true', () {
      expect(offer(enabled: false), StoreOffer.neutralNote);
      expect(offer(enabled: false, pending: true), StoreOffer.neutralNote);
      expect(offer(enabled: false, premium: true), StoreOffer.neutralNote);
    });

    test('a purchase in flight outranks everything else', () {
      // The family just paid; seeing an offer again would read as "it did not
      // work" while the server is still verifying the token.
      expect(offer(pending: true), StoreOffer.pendingVerification);
      expect(offer(pending: true, premium: true), StoreOffer.pendingVerification);
    });

    test('a store subscriber is never sold to again', () {
      expect(offer(premium: true), StoreOffer.managed);
    });

    test('no store, or no products, falls back to the neutral note', () {
      // Fail closed: the note is what Play always accepts, and an offer the
      // store cannot honor is worse than no offer.
      expect(offer(available: false), StoreOffer.neutralNote);
      expect(offer(products: false), StoreOffer.neutralNote);
    });

    test('with the rail on and products loaded, the offer shows', () {
      expect(offer(), StoreOffer.offer);
    });
  });

  group('gateway', () {
    test('only the store webhook writes play', () {
      expect(isStoreGateway('play'), isTrue);
      expect(isStoreGateway('asaas'), isFalse);
      expect(isStoreGateway(null), isFalse);
    });
  });

  group('the store master switch', () {
    test('defaults to false — off until the Play Console side exists', () {
      expect(const PublicSettings(null).storeBillingEnabled, isFalse);
      expect(const PublicSettings({}).storeBillingEnabled, isFalse);
    });

    test('is independent of the web rail switch', () {
      const settings = PublicSettings({
        'billing.enabled': 'true',
        'billing.store_enabled': 'false',
      });
      expect(settings.billingEnabled, isTrue);
      expect(settings.storeBillingEnabled, isFalse);
    });
  });
}
