using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-42 (PR1) — "Reativar assinatura" with NO charge today.
    //
    // Two halves, and the split is deliberate:
    //
    //   · The Edge Function guard chain (401 → 403 → billing disabled → row
    //     state → paid time → stored customer → payment method). EVERY test
    //     here stops at a guard that fires BEFORE the gateway is touched, so
    //     the suite never creates a sandbox subscription — same discipline as
    //     BillingCheckoutTests. Because dev may run with billing.enabled either
    //     way, the body asserts accept the "disabled" refusal as an alternative
    //     to the specific one, which keeps them honest in both states instead of
    //     silently passing for the wrong reason.
    //
    //   · The grace cron's treatment of the new 'scheduled' state, which is
    //     pure DB and therefore fully deterministic. This is the half that
    //     matters most: a reactivated row is no longer 'canceled', so without
    //     the migration's change a family whose scheduled invoice was never
    //     paid would keep premium forever. Both directions are covered — it
    //     lapses when the paid time is gone, and it is left alone while the
    //     paid time is still running.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingReactivateTests(E2EFamilyFixture fx)
    {
        private static string CheckoutUrl =>
            $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/billing-checkout";

        private const string DisabledRefusal = "assinaturas ainda não estão abertas";

        private static async Task<(HttpStatusCode Status, string Body)> CallAsync(
            object payload, string? accessToken)
        {
            using var http = new HttpClient();
            using var request = new HttpRequestMessage(HttpMethod.Post, CheckoutUrl);
            request.Headers.Add("apikey", TestEnv.AnonKey);
            if (accessToken is not null)
                request.Headers.Add("Authorization", $"Bearer {accessToken}");
            request.Content = new StringContent(
                JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            var response = await http.SendAsync(request);
            return (response.StatusCode, await response.Content.ReadAsStringAsync());
        }

        private async Task<Subscription> SeedAsync(long familyId, string tag, string status,
            DateTime? periodEnd = null, string? billingType = null, string? customerId = null)
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
            seeded.BillingType = billingType;
            seeded.ExternalCustomerId = customerId;
            return (await fx.Service.From<Subscription>().Update(seeded)).Models!.Single();
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

        // ── Guard chain ─────────────────────────────────────────────────────

        [Fact] // No user JWT → the platform itself refuses (verify_jwt).
        public async Task Reactivate_WithoutSession_IsRejected()
        {
            var (status, _) = await CallAsync(new { action = "reactivate" }, null);
            Assert.Equal(HttpStatusCode.Unauthorized, status);
        }

        [Fact] // Managing the subscription is admin-only, reactivation included.
        public async Task Reactivate_NonAdmin_IsForbidden()
        {
            var token = fx.Member.Auth.CurrentSession!.AccessToken!;
            var (status, body) = await CallAsync(new { action = "reactivate" }, token);
            Assert.Equal(HttpStatusCode.Forbidden, status);
            Assert.Contains("administradores", body);
        }

        [Fact] // An ACTIVE subscription has nothing to reactivate — refusing here
               // is what stops a second gateway subscription being created.
        public async Task Reactivate_ActiveSubscription_IsRefused()
        {
            var fam = await fx.CreateFamilyAsync("f42ra");
            await SeedAsync(fam.FamilyId, "f42ra", "active",
                periodEnd: DateTime.UtcNow.AddDays(20), billingType: "PIX", customerId: "cus_e2e_f42ra");

            var token = fam.Admin.Auth.CurrentSession!.AccessToken!;
            var (status, body) = await CallAsync(new { action = "reactivate" }, token);
            Assert.Equal(HttpStatusCode.Conflict, status);
            Assert.Contains("assinatura", body);   // both refusal texts mention it
        }

        [Fact] // Canceled AND already lapsed: there is no paid period left to
               // schedule against, so the answer must be "assine novamente",
               // never a subscription starting in the past.
        public async Task Reactivate_CanceledButLapsed_IsRefused()
        {
            var fam = await fx.CreateFamilyAsync("f42rl");
            await SeedAsync(fam.FamilyId, "f42rl", "canceled",
                periodEnd: DateTime.UtcNow.AddDays(-3), billingType: "PIX", customerId: "cus_e2e_f42rl");

            var token = fam.Admin.Auth.CurrentSession!.AccessToken!;
            var (status, body) = await CallAsync(new { action = "reactivate" }, token);
            Assert.Equal(HttpStatusCode.Conflict, status);
            Assert.True(
                body.Contains("período já pago terminou") || body.Contains(DisabledRefusal),
                $"unexpected refusal: {body}");
        }

        [Fact] // The asymmetry that defines the feature: a card family cannot be
               // rescheduled (no stored token) and must be told so explicitly,
               // with the reassurance that paying now loses nothing.
        public async Task Reactivate_CardMethod_IsRefusedWithPixGuidance()
        {
            var fam = await fx.CreateFamilyAsync("f42rc");
            await SeedAsync(fam.FamilyId, "f42rc", "canceled",
                periodEnd: DateTime.UtcNow.AddDays(15),
                billingType: "CREDIT_CARD", customerId: "cus_e2e_f42rc");

            var token = fam.Admin.Auth.CurrentSession!.AccessToken!;
            var (status, body) = await CallAsync(new { action = "reactivate" }, token);
            Assert.Equal(HttpStatusCode.Conflict, status);
            Assert.True(
                body.Contains("Pix e boleto") || body.Contains(DisabledRefusal),
                $"unexpected refusal: {body}");
        }

        [Fact] // Pix, paid time left, but the webhook never stored a customer —
               // nothing to bill against, so it degrades to a normal checkout
               // instead of erroring at the gateway.
        public async Task Reactivate_WithoutStoredCustomer_IsRefused()
        {
            var fam = await fx.CreateFamilyAsync("f42rn");
            await SeedAsync(fam.FamilyId, "f42rn", "canceled",
                periodEnd: DateTime.UtcNow.AddDays(15), billingType: "PIX", customerId: null);

            var token = fam.Admin.Auth.CurrentSession!.AccessToken!;
            var (status, body) = await CallAsync(new { action = "reactivate" }, token);
            Assert.Equal(HttpStatusCode.Conflict, status);
            Assert.True(
                body.Contains("cadastro de pagamento") || body.Contains(DisabledRefusal),
                $"unexpected refusal: {body}");
        }

        // ── The 'scheduled' state in the database ───────────────────────────

        [Fact] // The CHECK constraint accepts the new state and billing_type
               // round-trips — the two schema changes the rest depends on.
        public async Task ScheduledStatus_AndBillingType_Persist()
        {
            var fam = await fx.CreateFamilyAsync("f42sc");
            var row = await SeedAsync(fam.FamilyId, "f42sc", "scheduled",
                periodEnd: DateTime.UtcNow.AddDays(10), billingType: "PIX", customerId: "cus_e2e_f42sc");

            Assert.Equal("scheduled", row.Status);
            Assert.Equal("PIX", row.BillingType);
        }

        [Fact] // THE safety net. A scheduled subscription whose first invoice was
               // never paid must lapse exactly like a canceled one once the paid
               // period is gone — otherwise a missed PAYMENT_OVERDUE webhook
               // would leave the family premium forever, for free.
        public async Task ScheduledUnpaid_Lapsed_DowngradesToFree()
        {
            var fam = await fx.CreateFamilyAsync("f42sl");
            await SeedAsync(fam.FamilyId, "f42sl", "scheduled",
                periodEnd: DateTime.UtcNow.AddDays(-1), billingType: "PIX", customerId: "cus_e2e_f42sl");
            await SetPlanAsync(fam.FamilyId, "premium");

            await RunGraceAsync();

            Assert.Equal("free", await PlanOfAsync(fam.FamilyId));
        }

        [Fact] // The other direction, which the safety net must NOT break: while
               // the paid period is still running, a scheduled subscription is
               // exactly what the family expects — premium, no charge yet.
        public async Task Scheduled_WithPaidTimeLeft_KeepsPremium()
        {
            var fam = await fx.CreateFamilyAsync("f42sk");
            await SeedAsync(fam.FamilyId, "f42sk", "scheduled",
                periodEnd: DateTime.UtcNow.AddDays(12), billingType: "PIX", customerId: "cus_e2e_f42sk");
            await SetPlanAsync(fam.FamilyId, "premium");

            await RunGraceAsync();

            Assert.Equal("premium", await PlanOfAsync(fam.FamilyId));
        }
    }
}
