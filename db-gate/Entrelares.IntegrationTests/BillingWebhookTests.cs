using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-39 (PR1) — billing bookkeeping DB rules + the Asaas webhook contract:
    //   · subscriptions: family-scoped SELECT; no authenticated write path.
    //   · billing_events: invisible to authenticated (service_role only).
    //   · billing.* settings seeded; only the public ones readable by clients.
    //   · webhook: rejects calls without the shared token (401).
    //   · webhook happy paths (confirm → premium, refund → free, idempotent
    //     redelivery) run only when E2E_ASAAS_WEBHOOK_TOKEN is available —
    //     the token is a function secret; set it in e2e.local.env / CI to arm
    //     them (they early-return otherwise, mirroring how the secret itself
    //     is provisioned out-of-band).
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingWebhookTests(E2EFamilyFixture fx)
    {
        private static string? WebhookToken =>
            TestEnv.Optional("E2E_ASAAS_WEBHOOK_TOKEN");

        private static string WebhookUrl =>
            $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/billing-webhook";

        private static async Task<HttpResponseMessage> PostEventAsync(object payload, string? token)
        {
            using var http = new HttpClient();
            var request = new HttpRequestMessage(HttpMethod.Post, WebhookUrl)
            {
                Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json")
            };
            if (token is not null) request.Headers.Add("asaas-access-token", token);
            return await http.SendAsync(request);
        }

        private async Task<Subscription> SeedSubscriptionAsync(long familyId, string tag, string cycle = "monthly")
        {
            await fx.DeleteSubscriptionSeedAsync($"sub_e2e_{tag}");
            return (await fx.Service.From<Subscription>().Insert(new Subscription
            {
                FamilyId = familyId,
                ExternalCustomerId = $"cus_e2e_{tag}",
                ExternalSubscriptionId = $"sub_e2e_{tag}",
                Cycle = cycle,
                PriceCents = 1490
            })).Models!.Single();
        }

        // ── DB rules ─────────────────────────────────────────────────────────

        [Fact] // A member reads their own family's subscription; another family
               // sees nothing; and no authenticated user can write the table.
        public async Task Subscriptions_AreFamilyScoped_AndReadOnlyForClients()
        {
            var fam = await fx.CreateFamilyAsync("t39rls");
            await SeedSubscriptionAsync(fam.FamilyId, "t39rls");

            var mine = (await fam.Member.From<Subscription>().Get()).Models ?? [];
            Assert.Single(mine);
            Assert.Equal("pending", mine[0].Status);
            Assert.Equal(1490, mine[0].PriceCents);

            // The MAIN family sees none of the throwaway family's billing state.
            Assert.Empty((await fx.Founder.From<Subscription>().Get()).Models ?? []);

            // No authenticated write path: INSERT violates RLS loudly (42501)…
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.From<Subscription>().Insert(new Subscription
                {
                    FamilyId = fx.FamilyId,
                    Cycle = "monthly",
                    PriceCents = 1
                }));

            // …while UPDATE fails SILENTLY (no UPDATE policy ⇒ PostgREST matches
            // 0 rows, no error — bit us on the first CI run). The real assertion
            // is that the row is untouched afterwards.
            var hijack = mine[0];
            hijack.Status = "active";
            try { await fam.Member.From<Subscription>().Update(hijack); }
            catch { /* an error here is equally acceptable */ }
            var after = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("pending", after.Status);
        }

        [Fact] // The event ledger is service_role only: an authenticated client
               // gets an empty result (RLS), never gateway payloads.
        public async Task BillingEvents_AreInvisibleToClients()
        {
            var response = await fx.Founder.From<BillingEventProbe>().Get();
            Assert.Empty(response.Models ?? []);
        }

        [Fact] // billing.* settings: prices/enabled are public (the UI reads
               // them); grace_days joined them in U-22 (the overdue panel shows
               // the real grace deadline — enforcement stays in the server cron).
        public async Task BillingSettings_PublicRowsOnly()
        {
            var settings = (await fx.Founder.From<AppSetting>()
                .Filter("category", Supabase.Postgrest.Constants.Operator.Equals, "billing")
                .Get()).Models ?? [];

            var keys = settings.Select(s => s.Key).ToHashSet();
            Assert.Contains("billing.enabled", keys);
            Assert.Contains("billing.price_monthly_cents", keys);
            Assert.Contains("billing.price_annual_cents", keys);
            Assert.Contains("billing.grace_days", keys);

            // F-48: promotional launch price (Aug 2026) — 549, not 490: the
            // gateway refuses Pix/boleto charges under R$ 5,00 (QA round).
            Assert.Equal("549",
                settings.Single(s => s.Key == "billing.price_monthly_cents").Value);
            Assert.Equal("5490",
                settings.Single(s => s.Key == "billing.price_annual_cents").Value);
            Assert.Equal("7",
                settings.Single(s => s.Key == "billing.grace_days").Value);
        }

        // ── Webhook contract ─────────────────────────────────────────────────

        [Fact] // No shared token, no processing — the webhook is not an open door.
        public async Task Webhook_WithoutToken_IsRejected()
        {
            var response = await PostEventAsync(new
            {
                id = $"evt_e2e_unauth_{Guid.NewGuid():N}",
                @event = "PAYMENT_CONFIRMED"
            }, token: null);

            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        }

        [Fact] // Confirmed payment → subscription active + plan premium; the SAME
               // event redelivered is a no-op (idempotency ledger).
        public async Task Webhook_ConfirmedPayment_ActivatesPlan_Idempotently()
        {
            if (WebhookToken is null) return;   // armed by E2E_ASAAS_WEBHOOK_TOKEN

            var fam = await fx.CreateFamilyAsync("t39ok");
            var sub = await SeedSubscriptionAsync(fam.FamilyId, "t39ok");
            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = fam.FamilyId,
                ["p_plan"] = "free"
            });

            var eventId = $"evt_e2e_{Guid.NewGuid():N}";
            var payload = new
            {
                id = eventId,
                @event = "PAYMENT_CONFIRMED",
                payment = new
                {
                    id = "pay_e2e_1",
                    subscription = sub.ExternalSubscriptionId,
                    value = 14.90,
                    dueDate = DateTime.UtcNow.Date.ToString("yyyy-MM-dd")
                }
            };

            var first = await PostEventAsync(payload, WebhookToken);
            Assert.Equal(HttpStatusCode.OK, first.StatusCode);

            var updated = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("active", updated.Status);
            Assert.NotNull(updated.CurrentPeriodEnd);
            var premium = await fx.Service.Rpc("is_premium",
                new Dictionary<string, object> { ["p_family_id"] = fam.FamilyId });
            Assert.Contains("true", premium.Content ?? "");

            // Force the plan down, then REDELIVER the same event id: the ledger
            // must swallow it (no re-activation).
            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = fam.FamilyId,
                ["p_plan"] = "free"
            });
            var redelivery = await PostEventAsync(payload, WebhookToken);
            Assert.Equal(HttpStatusCode.OK, redelivery.StatusCode);
            var afterRedelivery = await fx.Service.Rpc("is_premium",
                new Dictionary<string, object> { ["p_family_id"] = fam.FamilyId });
            Assert.Contains("false", afterRedelivery.Content ?? "");
        }

        [Fact] // Refund → canceled + immediate downgrade; the family row and all
               // its data remain (downgrade never deletes anything).
        public async Task Webhook_Refund_DowngradesToFree()
        {
            if (WebhookToken is null) return;   // armed by E2E_ASAAS_WEBHOOK_TOKEN

            var fam = await fx.CreateFamilyAsync("t39ref");
            var sub = await SeedSubscriptionAsync(fam.FamilyId, "t39ref");

            await PostEventAsync(new
            {
                id = $"evt_e2e_{Guid.NewGuid():N}",
                @event = "PAYMENT_CONFIRMED",
                payment = new { id = "pay_e2e_2", subscription = sub.ExternalSubscriptionId,
                                dueDate = DateTime.UtcNow.Date.ToString("yyyy-MM-dd") }
            }, WebhookToken);

            var refund = await PostEventAsync(new
            {
                id = $"evt_e2e_{Guid.NewGuid():N}",
                @event = "PAYMENT_REFUNDED",
                payment = new { id = "pay_e2e_2", subscription = sub.ExternalSubscriptionId }
            }, WebhookToken);
            Assert.Equal(HttpStatusCode.OK, refund.StatusCode);

            var updated = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("canceled", updated.Status);
            var premium = await fx.Service.Rpc("is_premium",
                new Dictionary<string, object> { ["p_family_id"] = fam.FamilyId });
            Assert.Contains("false", premium.Content ?? "");

            // Data intact: the member still reads their family normally.
            Assert.Single((await fam.Member.From<Family>().Get()).Models ?? []);
        }
    }

    // Minimal probe model — test-local on purpose: the app client never touches
    // billing_events (service_role only), so no app model exists for it.
    [Supabase.Postgrest.Attributes.Table("billing_events")]
    public class BillingEventProbe : Supabase.Postgrest.Models.BaseModel
    {
        [Supabase.Postgrest.Attributes.PrimaryKey("id", false)]
        public long Id { get; set; }
    }
}
