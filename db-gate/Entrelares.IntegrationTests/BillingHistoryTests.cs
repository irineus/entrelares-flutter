using System.Net;
using System.Text;
using System.Text.Json;

namespace Entrelares.IntegrationTests
{
    // F-43 — the payment-history RPC (get_billing_history):
    //   · family ADMINS get a sanitized, family-scoped timeline (never the raw
    //     ledger payloads);
    //   · CONFIRMED+RECEIVED for the same gateway payment collapse to ONE row;
    //   · non-admins are refused by the DB itself;
    //   · another family's events never leak.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingHistoryTests(E2EFamilyFixture fx)
    {
        // Seeds ledger rows exactly as the webhook writes them (service key,
        // raw PostgREST — the table has no authenticated write path by design).
        private static async Task SeedEventAsync(long familyId, string eventType,
            string? paymentId = null, double? value = null, string? billingType = null,
            string? invoiceUrl = null)
        {
            using var http = new HttpClient();
            using var request = new HttpRequestMessage(
                HttpMethod.Post, $"{TestEnv.SupabaseUrl.TrimEnd('/')}/rest/v1/billing_events");
            TestEnv.ApplyKeyHeaders(request, TestEnv.ServiceRoleKey);
            request.Headers.Add("Prefer", "return=minimal");

            var payment = paymentId is null ? null : new Dictionary<string, object?>
            {
                ["id"] = paymentId,
                ["value"] = value,
                ["billingType"] = billingType,
                ["invoiceUrl"] = invoiceUrl,
            };
            request.Content = new StringContent(JsonSerializer.Serialize(new
            {
                event_id = $"evt_e2e_{Guid.NewGuid():N}",
                event_type = eventType,
                family_id = familyId,
                payload = new { payment },
            }), Encoding.UTF8, "application/json");

            var response = await http.SendAsync(request);
            Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        }

        private static async Task<JsonDocument> HistoryAsAsync(Supabase.Client caller)
        {
            var response = await caller.Rpc("get_billing_history", new Dictionary<string, object>());
            return JsonDocument.Parse(response.Content ?? "[]");
        }

        [Fact] // The admin timeline: one row per real payment (CONFIRMED+RECEIVED
               // deduped), refunds and grace downgrades included, receipt URL
               // exposed, newest first.
        public async Task Admin_SeesSanitizedTimeline_WithDedupe()
        {
            var fam = await fx.CreateFamilyAsync("f43hist");

            await SeedEventAsync(fam.FamilyId, "PAYMENT_CONFIRMED",
                paymentId: "pay_h1", value: 14.90, billingType: "PIX",
                invoiceUrl: "https://sandbox.asaas.com/i/h1");
            await SeedEventAsync(fam.FamilyId, "PAYMENT_RECEIVED",
                paymentId: "pay_h1", value: 14.90, billingType: "PIX",
                invoiceUrl: "https://sandbox.asaas.com/i/h1");
            await SeedEventAsync(fam.FamilyId, "PAYMENT_REFUNDED",
                paymentId: "pay_h1", value: 14.90, billingType: "PIX");
            await SeedEventAsync(fam.FamilyId, "GRACE_DOWNGRADE");
            // Internal/ops events never surface:
            await SeedEventAsync(fam.FamilyId, "CHECKOUT_ERROR");
            await SeedEventAsync(fam.FamilyId, "PAYMENT_CREATED", paymentId: "pay_h2");

            using var history = await HistoryAsAsync(fam.Admin);
            var rows = history.RootElement.EnumerateArray().ToList();
            var categories = rows.Select(r => r.GetProperty("category").GetString()).ToList();

            Assert.Equal(3, rows.Count);                       // payment (deduped) + refund + downgrade
            Assert.Single(categories, c => c == "payment");    // CONFIRMED+RECEIVED → one row
            Assert.Contains("refund", categories);
            Assert.Contains("downgraded", categories);
            Assert.DoesNotContain(null, categories);

            var payment = rows.Single(r => r.GetProperty("category").GetString() == "payment");
            Assert.Equal(14.90m, payment.GetProperty("amount").GetDecimal());
            Assert.Equal("PIX", payment.GetProperty("billing_type").GetString());
            Assert.Equal("https://sandbox.asaas.com/i/h1", payment.GetProperty("invoice_url").GetString());
        }

        [Fact] // Non-admin: the DB itself refuses.
        public async Task NonAdmin_IsRefused()
        {
            var fam = await fx.CreateFamilyAsync("f43deny");
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("get_billing_history", new Dictionary<string, object>()));
        }

        [Fact] // Cross-family isolation: the MAIN family's admin sees an empty
               // timeline — another family's events never leak.
        public async Task OtherFamilyEvents_NeverLeak()
        {
            var fam = await fx.CreateFamilyAsync("f43iso");
            await SeedEventAsync(fam.FamilyId, "PAYMENT_CONFIRMED", paymentId: "pay_iso", value: 14.90);

            using var history = await HistoryAsAsync(fx.Founder);
            Assert.Empty(history.RootElement.EnumerateArray());
        }
    }
}
