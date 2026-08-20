/// T-48 redesigned — the pure half of the STORE billing rail (Google Play).
///
/// The Digital Goods API the original T-48 described was a Chrome/TWA
/// mechanism; in a native app Play REQUIRES Play Billing for a digital
/// subscription sold inside the app. What survives from T-39 is everything
/// that matters: both rails converge on the same database — the store webhook
/// applies effects through the SAME `set_family_plan` and writes the SAME
/// `billing_events` ledger, idempotent by event id.
///
/// Two rules shape this file:
/// * **The price is Play's.** A store product carries its own price, set in the
///   Play Console per country; the client displays what the store answers and
///   never a number from `app_settings` (which keeps ruling the web rail). So
///   there is no price arithmetic here — only the mapping between a cycle and
///   the product that sells it.
/// * **The client never grants.** A purchase becomes Premium when the SERVER
///   has verified the token with the Play Developer API. Everything here is
///   about what to SHOW while that happens.
library;

/// The Play subscription products. Ids are a Play Console fact — changing one
/// orphans the purchases already made against it, so they are constants with a
/// test that pins them rather than configuration.
const String storeProductMonthly = 'premium_monthly';
const String storeProductAnnual = 'premium_annual';

/// The product that sells [cycle] (`monthly`/`annual`). Anything unknown maps
/// to the monthly product — the same default the rest of the client uses for a
/// missing cycle, and the cheaper of the two, so a bad value can never charge
/// more than the family expected.
String storeProductForCycle(String? cycle) =>
    cycle == 'annual' ? storeProductAnnual : storeProductMonthly;

/// The cycle a product id sells, or null when the id is not ours — a store
/// answer we do not recognise is never shown as an offer.
String? cycleForStoreProduct(String? productId) => switch (productId) {
      storeProductMonthly => 'monthly',
      storeProductAnnual => 'annual',
      _ => null,
    };

/// Where Play lets the subscriber manage (or cancel) what they bought. Play's
/// policy requires this route to exist inside the app, and it is also the
/// honest answer to "cancel": the store owns that subscription, not us.
String playManageSubscriptionUrl({
  required String packageName,
  String? productId,
}) {
  const base = 'https://play.google.com/store/account/subscriptions';
  return productId == null
      ? base
      : '$base?sku=$productId&package=$packageName';
}

/// What the store branch of the Premium section shows.
enum StoreOffer {
  /// The store rail is off (master switch) or the device cannot sell: keep the
  /// T-38 neutral note — no price, no link, no steering verb.
  neutralNote,

  /// Products loaded: real Play prices with their buy buttons.
  offer,

  /// A purchase exists and the SERVER has not confirmed it yet. The family is
  /// told it is being confirmed; nothing is granted here.
  pendingVerification,

  /// This family is already premium through the store — nothing to sell, only
  /// the Play management link.
  managed,
}

/// The store branch's state machine.
///
/// The order is deliberate: a purchase in flight outranks everything (the
/// family just paid and deserves to see that we know), an already-premium
/// store subscriber is never sold to again, and the neutral note is the
/// fail-closed default — whenever the rail is off, the device cannot answer,
/// or no product came back, the app falls back to what Play always accepts.
StoreOffer computeStoreOffer({
  required bool storeBillingEnabled,
  required bool storeAvailable,
  required bool hasProducts,
  required bool purchasePending,
  required bool premiumThroughStore,
}) {
  if (!storeBillingEnabled) return StoreOffer.neutralNote;
  if (purchasePending) return StoreOffer.pendingVerification;
  if (premiumThroughStore) return StoreOffer.managed;
  if (!storeAvailable || !hasProducts) return StoreOffer.neutralNote;
  return StoreOffer.offer;
}

/// Whether the subscription row was written by the store rail. `gateway` is
/// the column both webhooks write; the store one writes `play`.
bool isStoreGateway(String? gateway) => gateway == 'play';
