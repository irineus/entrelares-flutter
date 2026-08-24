/// T-39: the family's paid subscription. Mirrors
/// `Entrelares/Models/Subscription.cs` — one row per family, created by the
/// `billing-checkout` Edge Function and kept current by the billing webhook.
/// The client only READS (RLS: family-scoped SELECT); every write happens
/// server-side with the service key. Entitlement itself stays on
/// `families.plan` (F-32) — this row is bookkeeping/UI state (renewal date,
/// overdue warning, manage-subscription context).
class Subscription {
  final int id;
  final int familyId;

  /// Which rail wrote the row. `asaas` today; the T-48 store rail writes
  /// `play` through its own webhook into this SAME table.
  final String gateway;

  final String? externalCustomerId;
  final String? externalSubscriptionId;

  /// `pending` | `scheduled` | `active` | `overdue` | `canceled`.
  /// `scheduled` (F-42): the gateway subscription exists with its first
  /// invoice due at [currentPeriodEnd] — nothing was paid for it yet.
  final String status;

  /// F-42: payment method of the last confirmed payment, verbatim from the
  /// gateway (PIX, BOLETO, CREDIT_CARD, UNDEFINED…). Null = never paid. Only
  /// invoice-style methods can be rescheduled without charging today.
  final String? billingType;

  /// F-48: true when the row came from the Pix avulso checkout (single,
  /// non-recurring charge). A settled avulso rests at status `canceled` with
  /// the paid period on [currentPeriodEnd]; never F-42-reactivatable.
  final bool singleCharge;

  /// `monthly` | `annual`.
  final String cycle;

  final int priceCents;
  final DateTime? currentPeriodEnd;
  final DateTime? overdueSince;
  final DateTime? canceledAt;

  const Subscription({
    required this.id,
    required this.familyId,
    this.gateway = 'asaas',
    this.externalCustomerId,
    this.externalSubscriptionId,
    this.status = 'pending',
    this.billingType,
    this.singleCharge = false,
    this.cycle = 'monthly',
    this.priceCents = 0,
    this.currentPeriodEnd,
    this.overdueSince,
    this.canceledAt,
  });

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        id: (json['id'] as num).toInt(),
        familyId: (json['family_id'] as num?)?.toInt() ?? 0,
        gateway: (json['gateway'] as String?) ?? 'asaas',
        externalCustomerId: json['external_customer_id'] as String?,
        externalSubscriptionId: json['external_subscription_id'] as String?,
        status: (json['status'] as String?) ?? 'pending',
        billingType: json['billing_type'] as String?,
        singleCharge: (json['single_charge'] as bool?) ?? false,
        cycle: (json['cycle'] as String?) ?? 'monthly',
        priceCents: (json['price_cents'] as num?)?.toInt() ?? 0,
        currentPeriodEnd: _utc(json['current_period_end'] as String?),
        overdueSince: _utc(json['overdue_since'] as String?),
        canceledAt: _utc(json['canceled_at'] as String?),
      );

  static DateTime? _utc(String? wire) =>
      wire == null ? null : DateTime.parse(wire).toUtc();
}

/// F-43: one sanitized entry of the family's billing timeline, as returned by
/// the admin-only `get_billing_history` RPC. The server decides what a payer
/// may see — the client never assembles this from raw ledger rows.
class BillingHistoryEntry {
  final DateTime occurredAt;

  /// `payment` | `refund` | `overdue` | `canceled` | `downgraded` | other —
  /// mapped to a catalogue key by `historyCategoryKey` so the label follows
  /// the READER's language (U-13).
  final String? category;

  /// Amount in reais (the RPC returns numeric), or null for entries that move
  /// no money (a cancellation, a downgrade).
  final double? amount;

  final String? billingType;

  /// The gateway's receipt link, when the entry has one.
  final String? invoiceUrl;

  const BillingHistoryEntry({
    required this.occurredAt,
    this.category,
    this.amount,
    this.billingType,
    this.invoiceUrl,
  });

  factory BillingHistoryEntry.fromJson(Map<String, dynamic> json) =>
      BillingHistoryEntry(
        occurredAt: DateTime.parse(json['occurred_at'] as String).toUtc(),
        category: json['category'] as String?,
        amount: (json['amount'] as num?)?.toDouble(),
        billingType: json['billing_type'] as String?,
        invoiceUrl: json['invoice_url'] as String?,
      );

  /// The amount in CENTS, which is what `formatPriceBrl` speaks. Rounded like
  /// the web's `(int)Math.Round(amount * 100)` — the wire value is a decimal
  /// and binary doubles would otherwise truncate 14.90 into 1489.
  int? get amountCents =>
      amount == null ? null : (amount! * 100).roundToDouble().toInt();
}
