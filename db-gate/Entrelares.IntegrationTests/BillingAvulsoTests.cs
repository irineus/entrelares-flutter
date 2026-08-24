using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-48 (block 3) — Pix avulso: a single NON-RECURRING charge. The webhook
    // half is what the database/functions own and what these tests pin:
    //   · a payment WITHOUT a subscription id that matches a single_charge row
    //     (externalReference `family:<id>`) settles it as canceled-with-paid-
    //     time: premium until +1 cycle, no recurrence, billing_type stored;
    //   · a second avulso payment is ADDITIVE (extends from the paid end);
    //   · PAYMENT_OVERDUE never touches an avulso row (an unpaid single charge
    //     is an abandoned checkout, not a failed renewal).
    // Like the other webhook suites, the happy paths are armed by
    // E2E_ASAAS_WEBHOOK_TOKEN (a function secret) and early-return without it.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingAvulsoTests(E2EFamilyFixture fx)
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

        // An avulso row as billing-checkout creates it: pending, single_charge,
        // NO gateway subscription id (a DETACHED charge never has one). The
        // family is fresh per test, so no fixed unique key needs delete-first.
        private async Task<Subscription> SeedAvulsoAsync(long familyId, string cycle = "monthly")
        {
            return (await fx.Service.From<Subscription>().Insert(new Subscription
            {
                FamilyId = familyId,
                Cycle = cycle,
                PriceCents = 490,
                SingleCharge = true
            })).Models!.Single();
        }

        // The webhook folds a STILL-RUNNING trial into the paid period (F-46),
        // which would blur the +1-month assertions below — clear it so the
        // period math is exact. (The trial interplay itself is recurring-path
        // behavior already covered by the F-46 delivery.)
        private async Task ClearTrialAsync(long familyId)
        {
            var family = (await fx.Service.From<Family>()
                .Filter("id", Supabase.Postgrest.Constants.Operator.Equals, familyId.ToString())
                .Get()).Models!.Single();
            family.TrialEndsAt = null;
            await fx.Service.From<Family>().Update(family);
        }

        [Fact] // Settlement: payment with NO subscription id + externalReference
               // family:<id> → the single_charge row rests at 'canceled' with
               // one cycle of paid time, Pix recorded, plan premium.
        public async Task AvulsoPayment_SettlesAsCanceledWithPaidPeriod()
        {
            if (WebhookToken is null) return;   // armed by E2E_ASAAS_WEBHOOK_TOKEN

            var fam = await fx.CreateFamilyAsync("f48av1");
            await ClearTrialAsync(fam.FamilyId);
            await SeedAvulsoAsync(fam.FamilyId);

            var due = DateTime.UtcNow.Date;
            var response = await PostEventAsync(new
            {
                id = $"evt_e2e_{Guid.NewGuid():N}",
                @event = "PAYMENT_RECEIVED",
                payment = new
                {
                    id = $"pay_e2e_{Guid.NewGuid():N}",
                    value = 4.90,
                    billingType = "PIX",
                    externalReference = $"family:{fam.FamilyId}",
                    dueDate = due.ToString("yyyy-MM-dd")
                }
            }, WebhookToken);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            var updated = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("canceled", updated.Status);
            Assert.True(updated.SingleCharge);
            Assert.NotNull(updated.CanceledAt);
            Assert.Equal("PIX", updated.BillingType);
            Assert.NotNull(updated.CurrentPeriodEnd);
            Assert.True((updated.CurrentPeriodEnd!.Value - due.AddMonths(1)).Duration() < TimeSpan.FromDays(2),
                $"period end {updated.CurrentPeriodEnd} not ~1 month after {due}");

            var premium = await fx.Service.Rpc("is_premium",
                new Dictionary<string, object> { ["p_family_id"] = fam.FamilyId });
            Assert.Contains("true", premium.Content ?? "");
        }

        [Fact] // Renewing by a SECOND avulso is additive: the new cycle counts
               // from the end of the already-paid one, never from the payment
               // date — and the row stays non-recurring ('canceled').
        public async Task SecondAvulsoPayment_ExtendsFromThePaidEnd()
        {
            if (WebhookToken is null) return;   // armed by E2E_ASAAS_WEBHOOK_TOKEN

            var fam = await fx.CreateFamilyAsync("f48av2");
            await ClearTrialAsync(fam.FamilyId);
            await SeedAvulsoAsync(fam.FamilyId);

            var due = DateTime.UtcNow.Date;
            foreach (var _ in Enumerable.Range(0, 2))
            {
                var response = await PostEventAsync(new
                {
                    id = $"evt_e2e_{Guid.NewGuid():N}",
                    @event = "PAYMENT_RECEIVED",
                    payment = new
                    {
                        id = $"pay_e2e_{Guid.NewGuid():N}",
                        value = 4.90,
                        billingType = "PIX",
                        externalReference = $"family:{fam.FamilyId}",
                        dueDate = due.ToString("yyyy-MM-dd")
                    }
                }, WebhookToken);
                Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            }

            var updated = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("canceled", updated.Status);
            Assert.True((updated.CurrentPeriodEnd!.Value - due.AddMonths(2)).Duration() < TimeSpan.FromDays(3),
                $"period end {updated.CurrentPeriodEnd} not ~2 months after {due} — second payment was not additive");
        }

        [Fact] // PAYMENT_OVERDUE on an avulso row is a no-op: no dunning state,
               // no overdue panel — an expired avulso is a lapse, not a failed
               // renewal. (For recurring rows the overdue path is untouched.)
        public async Task Overdue_NeverTouchesAnAvulsoRow()
        {
            if (WebhookToken is null) return;   // armed by E2E_ASAAS_WEBHOOK_TOKEN

            var fam = await fx.CreateFamilyAsync("f48av3");
            await SeedAvulsoAsync(fam.FamilyId);

            var response = await PostEventAsync(new
            {
                id = $"evt_e2e_{Guid.NewGuid():N}",
                @event = "PAYMENT_OVERDUE",
                payment = new
                {
                    id = $"pay_e2e_{Guid.NewGuid():N}",
                    externalReference = $"family:{fam.FamilyId}"
                }
            }, WebhookToken);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            var updated = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("pending", updated.Status);
            Assert.Null(updated.OverdueSince);
        }
    }
}
