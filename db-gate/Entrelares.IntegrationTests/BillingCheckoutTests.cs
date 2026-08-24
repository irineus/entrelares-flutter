using System.Net;
using System.Text;
using System.Text.Json;

namespace Entrelares.IntegrationTests
{
    // T-39 (PR2) — the billing-checkout guard chain, in order: 401 without a
    // user JWT (verify_jwt stays ON for this function), 403 for a non-admin
    // member, 409 while billing.enabled=false (the dev default until go-live).
    // The Asaas key is deliberately NOT needed: every test stops at a guard
    // that fires before the gateway is touched.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingCheckoutTests(E2EFamilyFixture fx)
    {
        private static string CheckoutUrl =>
            $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/billing-checkout";

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

        [Fact] // No user JWT → the platform itself refuses (verify_jwt).
        public async Task Checkout_WithoutSession_IsRejected()
        {
            var (status, _) = await CallAsync(new { action = "checkout", cycle = "monthly" }, null);
            Assert.Equal(HttpStatusCode.Unauthorized, status);
        }

        [Fact] // A non-admin member cannot start a checkout (the payer is an admin).
        public async Task Checkout_NonAdmin_IsForbidden()
        {
            var token = fx.Member.Auth.CurrentSession!.AccessToken!;
            var (status, body) = await CallAsync(new { action = "checkout", cycle = "monthly" }, token);
            Assert.Equal(HttpStatusCode.Forbidden, status);
            Assert.Contains("administradores", body);
        }

        [Fact] // The guard chain refuses with 409 regardless of the live
               // billing.enabled state — asserted against a family that already
               // HAS an active subscription, so the test is deterministic in
               // both environments (flag off → "assinaturas não abertas"; flag
               // on → "família já tem uma assinatura") and NEVER reaches the
               // gateway (no payment link side effects). The original version
               // assumed the flag was off and broke the moment dev enabled
               // billing for the sandbox QA.
        public async Task Checkout_DisabledOrAlreadySubscribed_IsRefused()
        {
            var fam = await fx.CreateFamilyAsync("t39co");
            await fx.DeleteSubscriptionSeedAsync("sub_e2e_t39co");
            var seeded = (await fx.Service.From<Entrelares.Models.Subscription>()
                .Insert(new Entrelares.Models.Subscription
                {
                    FamilyId = fam.FamilyId,
                    ExternalSubscriptionId = "sub_e2e_t39co",
                    Cycle = "monthly",
                    PriceCents = 1490
                })).Models!.Single();
            seeded.Status = "active";
            await fx.Service.From<Entrelares.Models.Subscription>().Update(seeded);

            var token = fam.Admin.Auth.CurrentSession!.AccessToken!;
            var (status, body) = await CallAsync(new { action = "checkout", cycle = "monthly" }, token);
            Assert.Equal(HttpStatusCode.Conflict, status);
            Assert.Contains("assinatura", body);   // both refusal texts mention it
        }

        [Fact] // Cancel with no subscription: same guard chain, then 404.
               // (Guard order puts enabled BEFORE the row lookup, so with billing
               // disabled this is a 409 — the assert accepts the disabled answer
               // too, keeping the test honest in both dev states.)
        public async Task Cancel_WithoutSubscription_FailsCleanly()
        {
            var token = fx.Founder.Auth.CurrentSession!.AccessToken!;
            var (status, _) = await CallAsync(new { action = "cancel" }, token);
            Assert.True(status is HttpStatusCode.NotFound or HttpStatusCode.Conflict,
                $"expected 404 (no subscription) or 409 (billing disabled), got {(int)status}");
        }
    }
}
