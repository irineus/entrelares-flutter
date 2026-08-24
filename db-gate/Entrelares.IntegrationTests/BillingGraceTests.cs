using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-39 (PR3) — the grace-period downgrade cron (billing_grace_downgrade):
    //   · canceled subscription whose paid period lapsed → plan free;
    //   · overdue subscription past billing.grace_days → plan free, status
    //     stays 'overdue' (a late payment can still reactivate via webhook);
    //   · paid time remaining → untouched;
    //   · the downgrade never deletes data and is service_role only.
    // Plus the additive activation rules (webhook, armed by E2E_ASAAS_WEBHOOK_TOKEN):
    // re-subscribing with paid time left EXTENDS from the old period end, and a
    // first payment DURING the trial extends from the trial end (F-46).
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingGraceTests(E2EFamilyFixture fx)
    {
        private async Task<Subscription> SeedAsync(long familyId, string tag,
            string status, DateTime? periodEnd = null, DateTime? overdueSince = null)
        {
            await fx.DeleteSubscriptionSeedAsync($"sub_e2e_{tag}");
            var seeded = (await fx.Service.From<Subscription>().Insert(new Subscription
            {
                FamilyId = familyId,
                ExternalSubscriptionId = $"sub_e2e_{tag}",
                Cycle = "monthly",
                PriceCents = 1490
            })).Models!.Single();

            seeded.Status = status;
            seeded.CurrentPeriodEnd = periodEnd;
            seeded.OverdueSince = overdueSince;
            return (await fx.Service.From<Subscription>().Update(seeded)).Models!.Single();
        }

        // F-46: fresh E2E families carry the 30-day trial default, which the
        // webhook now folds into the paid period — tests that model a
        // POST-trial family must clear it, and the trial test pins its own.
        private async Task SetTrialAsync(long familyId, DateTime? endsAtUtc)
        {
            var famRow = (await fx.Service.From<Family>()
                .Filter("id", Supabase.Postgrest.Constants.Operator.Equals, familyId.ToString())
                .Get()).Models!.Single();
            famRow.TrialEndsAt = endsAtUtc;
            await fx.Service.From<Family>().Update(famRow);
        }

        private async Task SetPlanAsync(long familyId, string plan) =>
            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId,
                ["p_plan"] = plan
            });

        private async Task<string> PlanOfAsync(long familyId) =>
            (await fx.Service.From<Family>()
                .Filter("id", Supabase.Postgrest.Constants.Operator.Equals, familyId.ToString())
                .Get()).Models!.Single().Plan;

        private Task RunGraceAsync() =>
            fx.Service.Rpc("billing_grace_downgrade", new Dictionary<string, object>());

        [Fact] // Canceled + lapsed → free; the family's data survives untouched
               // and the ledger records the downgrade.
        public async Task LapsedCanceled_DowngradesToFree_KeepsData()
        {
            var fam = await fx.CreateFamilyAsync("t39gr1");
            await SeedAsync(fam.FamilyId, "t39gr1", "canceled",
                periodEnd: DateTime.UtcNow.AddDays(-1));
            await SetPlanAsync(fam.FamilyId, "premium");

            await RunGraceAsync();

            Assert.Equal("free", await PlanOfAsync(fam.FamilyId));
            // Data intact: the member still reads their family normally.
            Assert.Single((await fam.Member.From<Family>().Get()).Models ?? []);
            // Idempotent: a second sweep changes nothing (already free → filtered out).
            await RunGraceAsync();
            Assert.Equal("free", await PlanOfAsync(fam.FamilyId));
        }

        [Fact] // Overdue past the grace window → free, but status STAYS overdue
               // so a late payment still reactivates through the webhook.
        public async Task OverdueBeyondGrace_DowngradesToFree_StatusStaysOverdue()
        {
            var fam = await fx.CreateFamilyAsync("t39gr2");
            await SeedAsync(fam.FamilyId, "t39gr2", "overdue",
                overdueSince: DateTime.UtcNow.AddDays(-8));   // grace default = 7
            await SetPlanAsync(fam.FamilyId, "premium");

            await RunGraceAsync();

            Assert.Equal("free", await PlanOfAsync(fam.FamilyId));
            var sub = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("overdue", sub.Status);
        }

        [Fact] // Paid time remaining (canceled or fresh overdue) → untouched.
        public async Task WithinPaidOrGraceWindow_IsLeftAlone()
        {
            var fam = await fx.CreateFamilyAsync("t39gr3");
            await SeedAsync(fam.FamilyId, "t39gr3", "canceled",
                periodEnd: DateTime.UtcNow.AddDays(10));
            await SetPlanAsync(fam.FamilyId, "premium");

            await RunGraceAsync();

            Assert.Equal("premium", await PlanOfAsync(fam.FamilyId));
        }

        [Fact] // The sweep is service_role only — no client can trigger downgrades.
        public async Task GraceDowngrade_IsDeniedToClients()
        {
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.Rpc("billing_grace_downgrade", new Dictionary<string, object>()));
        }

        // ── Additive renewal (webhook, armed by E2E_ASAAS_WEBHOOK_TOKEN) ─────

        [Fact] // Re-subscribing while paid time remains EXTENDS from the old
               // period end instead of restarting from the payment date.
        public async Task Renewal_WithPaidTimeLeft_ExtendsFromOldPeriodEnd()
        {
            var token = TestEnv.Optional("E2E_ASAAS_WEBHOOK_TOKEN");
            if (token is null) return;   // armed by the webhook shared token

            var fam = await fx.CreateFamilyAsync("t39add");
            // Post-trial family: without this, the fresh family's default
            // 30-day trial would win the max and shift the expected base (F-46).
            await SetTrialAsync(fam.FamilyId, null);
            var sub = await SeedAsync(fam.FamilyId, "t39add", "canceled",
                periodEnd: DateTime.UtcNow.Date.AddDays(15));   // half a cycle left

            using var http = new HttpClient();
            var request = new HttpRequestMessage(HttpMethod.Post,
                $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/billing-webhook")
            {
                Content = new StringContent(JsonSerializer.Serialize(new
                {
                    id = $"evt_e2e_{Guid.NewGuid():N}",
                    @event = "PAYMENT_RECEIVED",
                    payment = new
                    {
                        id = "pay_e2e_add",
                        subscription = sub.ExternalSubscriptionId,
                        dueDate = DateTime.UtcNow.Date.ToString("yyyy-MM-dd")
                    }
                }), Encoding.UTF8, "application/json")
            };
            request.Headers.Add("asaas-access-token", token);
            var response = await http.SendAsync(request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            var updated = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("active", updated.Status);
            // Base = the OLD period end (15 days out), not today: +1 month on top.
            var expected = DateTime.UtcNow.Date.AddDays(15).AddMonths(1);
            Assert.NotNull(updated.CurrentPeriodEnd);
            Assert.True(Math.Abs((updated.CurrentPeriodEnd!.Value.Date - expected).TotalDays) <= 1,
                $"period end {updated.CurrentPeriodEnd} should extend from the old end (~{expected})");
        }

        [Fact] // F-46: the trial is a first payment of R$ 0 — paying DURING the
               // trial starts the paid cycle at the trial end (the remaining
               // days are added, never forfeited) and clears the consumed trial.
        public async Task FirstPayment_DuringTrial_ExtendsFromTrialEnd()
        {
            var token = TestEnv.Optional("E2E_ASAAS_WEBHOOK_TOKEN");
            if (token is null) return;   // armed by the webhook shared token

            var fam = await fx.CreateFamilyAsync("t46tr");
            // Pin the trial to a known instant (fresh families default to ~+30d).
            var trialEnd = DateTime.UtcNow.Date.AddDays(20);
            await SetTrialAsync(fam.FamilyId, trialEnd);
            // First payment: the checkout row has no paid period yet.
            var sub = await SeedAsync(fam.FamilyId, "t46tr", "pending");

            using var http = new HttpClient();
            var request = new HttpRequestMessage(HttpMethod.Post,
                $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/billing-webhook")
            {
                Content = new StringContent(JsonSerializer.Serialize(new
                {
                    id = $"evt_e2e_{Guid.NewGuid():N}",
                    @event = "PAYMENT_RECEIVED",
                    payment = new
                    {
                        id = "pay_e2e_trial",
                        subscription = sub.ExternalSubscriptionId,
                        dueDate = DateTime.UtcNow.Date.ToString("yyyy-MM-dd")
                    }
                }), Encoding.UTF8, "application/json")
            };
            request.Headers.Add("asaas-access-token", token);
            var response = await http.SendAsync(request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);

            var updated = (await fam.Member.From<Subscription>().Get()).Models!.Single();
            Assert.Equal("active", updated.Status);
            // Base = the TRIAL end (20 days out), not the payment date: +1 month on top.
            var expected = trialEnd.AddMonths(1);
            Assert.NotNull(updated.CurrentPeriodEnd);
            Assert.True(Math.Abs((updated.CurrentPeriodEnd!.Value.Date - expected).TotalDays) <= 1,
                $"period end {updated.CurrentPeriodEnd} should extend from the trial end (~{expected})");

            // The consumed trial is cleared — the paid period is now the single
            // source of the entitlement window; the plan carries the premium.
            var famRow = (await fx.Service.From<Family>()
                .Filter("id", Supabase.Postgrest.Constants.Operator.Equals, fam.FamilyId.ToString())
                .Get()).Models!.Single();
            Assert.Equal("premium", famRow.Plan);
            Assert.Null(famRow.TrialEndsAt);
        }
    }
}
