using Supabase.Postgrest.Attributes;
using Supabase.Postgrest.Models;

namespace Entrelares.Models
{
    // T-39: the family's paid subscription (gateway: Asaas). One row per family,
    // created by the billing-checkout Edge Function and kept current by the
    // billing-webhook. The client only READS (RLS: family-scoped SELECT); every
    // write happens server-side with the service key. Entitlement itself stays
    // on families.plan (F-32) — this row is bookkeeping/UI state (renewal date,
    // overdue warning, manage-subscription context).
    [Table("subscriptions")]
    public class Subscription : BaseModel
    {
        [PrimaryKey("id", false)]
        public long Id { get; set; }

        [Column("family_id")]
        public long FamilyId { get; set; }

        // T-48 (T-53 lote 5): 'asaas' (web rail) | 'play' (store rail). Both
        // webhooks write this same table and apply through set_family_plan; the
        // column says which one owns the row, and therefore WHERE the family
        // cancels. The frozen Blazor UI never shows a store row — it exists
        // here so the server suites can assert the schema they protect.
        [Column("gateway")]
        public string Gateway { get; set; } = "asaas";

        [Column("external_customer_id")]
        public string? ExternalCustomerId { get; set; }

        [Column("external_subscription_id")]
        public string? ExternalSubscriptionId { get; set; }

        // pending | scheduled | active | overdue | canceled
        // 'scheduled' (F-42): the gateway subscription exists with its first
        // invoice due at current_period_end — nothing was paid for it yet.
        [Column("status")]
        public string Status { get; set; } = "pending";

        // F-42: payment method of the last confirmed payment, verbatim from the
        // gateway (PIX, BOLETO, CREDIT_CARD, UNDEFINED…). NULL = never paid.
        // Only invoice-style methods can be rescheduled without charging today.
        [Column("billing_type")]
        public string? BillingType { get; set; }

        // F-48: true when the row came from the Pix avulso checkout (single,
        // non-recurring charge). A settled avulso rests at status 'canceled'
        // with the paid period on current_period_end; never F-42-reactivatable.
        [Column("single_charge")]
        public bool SingleCharge { get; set; }

        // monthly | annual
        [Column("cycle")]
        public string Cycle { get; set; } = "monthly";

        [Column("price_cents")]
        public int PriceCents { get; set; }

        [Column("current_period_end")]
        public DateTime? CurrentPeriodEnd { get; set; }

        [Column("overdue_since")]
        public DateTime? OverdueSince { get; set; }

        [Column("canceled_at")]
        public DateTime? CanceledAt { get; set; }

        // S-15/B-3: when the "grace period ending" warning went out for the
        // CURRENT overdue cycle (NULL = not warned). Reset by a DB trigger
        // whenever overdue_since changes, so a family that recovers and later
        // falls overdue again is warned again.
        [Column("grace_warning_sent_at")]
        public DateTime? GraceWarningSentAt { get; set; }

        // T-48: Play's identity for "this Google account bought this product".
        // UNIQUE in the database — one purchase funds one family, so a replayed
        // receipt cannot buy Premium twice.
        [Column("store_purchase_token")]
        public string? StorePurchaseToken { get; set; }

        // T-48: which Play product sold it (premium_monthly | premium_annual).
        [Column("store_product_id")]
        public string? StoreProductId { get; set; }

        [Column("created_at")]
        public DateTime CreatedAt { get; set; }
    }
}
