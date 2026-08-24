using System.Net;
using System.Text;
using System.Text.Json;
using Entrelares.Models;
using Supabase.Postgrest;

namespace Entrelares.IntegrationTests
{
    // T-48 (redesigned, T-53 lote 5) — the DATABASE half of the store rail.
    //
    // What is worth an integration test here is not the Play API (we cannot
    // fake Google in CI) but the rules that protect the money regardless of
    // what the client sends:
    //   · `play` is a first-class gateway, and an invented one still is not;
    //   · one purchase token funds ONE family — the unique index is what stops
    //     a replayed receipt, so it is asserted against the real database;
    //   · the store columns are readable by the family and writable by nobody
    //     but service_role, like the rest of the row;
    //   · `billing.store_enabled` is seeded PUBLIC and false, which is what
    //     keeps the store build on the neutral T-38 note until the console
    //     side exists;
    //   · the verify function refuses an anonymous caller (its own auth, since
    //     it runs without the platform gate).
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingStoreTests(E2EFamilyFixture fx)
    {
        private static string VerifyUrl =>
            $"{TestEnv.SupabaseUrl.TrimEnd('/')}/functions/v1/billing-store-verify";

        /// <summary>Removes every row this suite could have left on a family.
        /// Called in a `finally` by each seeding test: a seeded subscription
        /// that outlives its test poisons the SIBLING suites, which assert on
        /// "this family has no subscription" (that is exactly how the first CI
        /// run of this file broke `BillingCheckoutTests`).</summary>
        private async Task ClearSubscriptionAsync(long familyId) =>
            await fx.Service.From<Subscription>()
                .Filter("family_id", Constants.Operator.Equals, familyId)
                .Delete();

        private async Task<Subscription> SeedStoreSubscriptionAsync(
            long familyId, string tag, string token)
        {
            await fx.DeleteSubscriptionSeedAsync($"sub_e2e_{tag}");
            await fx.Service.From<Subscription>()
                .Filter("family_id", Constants.Operator.Equals, familyId)
                .Delete();

            return (await fx.Service.From<Subscription>().Insert(new Subscription
            {
                FamilyId = familyId,
                Gateway = "play",
                ExternalSubscriptionId = $"sub_e2e_{tag}",
                Status = "active",
                Cycle = "monthly",
                PriceCents = 690,
                BillingType = "PLAY",
                StorePurchaseToken = token,
                StoreProductId = "premium_monthly",
                CurrentPeriodEnd = DateTime.UtcNow.AddDays(30),
            })).Models.Single();
        }

        [Fact] // The store rail is a gateway the schema knows about.
        public async Task PlayIsAValidGateway()
        {
            var token = $"tok_e2e_{fx.RunId}_valid";
            try
            {
                var row = await SeedStoreSubscriptionAsync(fx.FamilyId, "play_valid", token);
                Assert.Equal("play", row.Gateway);
                Assert.Equal(token, row.StorePurchaseToken);
            }
            finally
            {
                await ClearSubscriptionAsync(fx.FamilyId);
            }
        }

        [Fact] // …and an invented one still is not: the CHECK is the guard that
               // keeps a typo from creating a third, unowned rail.
        public async Task AnUnknownGatewayIsRefused()
        {
            await ClearSubscriptionAsync(fx.FamilyBId);

            var boom = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Service.From<Subscription>().Insert(new Subscription
                {
                    FamilyId = fx.FamilyBId,
                    Gateway = "stripe",
                    Status = "active",
                    Cycle = "monthly",
                    PriceCents = 690,
                }));

            Assert.Contains("gateway", boom.Message, StringComparison.OrdinalIgnoreCase);
        }

        [Fact] // ONE purchase funds ONE family. Without this, the same receipt
               // replayed by a second family buys Premium twice off one payment
               // — and the client cannot be the thing that prevents it.
        public async Task APurchaseTokenCannotFundTwoFamilies()
        {
            var token = $"tok_e2e_{fx.RunId}_shared";
            try
            {
                await SeedStoreSubscriptionAsync(fx.FamilyId, "play_first", token);
                await ClearSubscriptionAsync(fx.FamilyBId);

                var boom = await Assert.ThrowsAnyAsync<Exception>(() =>
                    fx.Service.From<Subscription>().Insert(new Subscription
                    {
                        FamilyId = fx.FamilyBId,
                        Gateway = "play",
                        Status = "active",
                        Cycle = "monthly",
                        PriceCents = 690,
                        StorePurchaseToken = token,
                        StoreProductId = "premium_monthly",
                    }));

                Assert.Contains("duplicate", boom.Message, StringComparison.OrdinalIgnoreCase);
            }
            finally
            {
                await ClearSubscriptionAsync(fx.FamilyId);
                await ClearSubscriptionAsync(fx.FamilyBId);
            }
        }

        [Fact] // The family sees its own store row (the UI needs status and
               // period end) and cannot write a single column of it.
        public async Task TheFamilyReadsItsStoreRowAndCannotWriteIt()
        {
            var token = $"tok_e2e_{fx.RunId}_rls";
            try
            {
                var row = await SeedStoreSubscriptionAsync(fx.FamilyId, "play_rls", token);

                var visible = await fx.Founder.From<Subscription>().Get();
                var mine = Assert.Single(visible.Models);
                Assert.Equal("play", mine.Gateway);
                Assert.Equal("premium_monthly", mine.StoreProductId);

                // No authenticated write path exists — the store functions
                // write with the secret key, exactly like the Asaas webhook.
                // The UPDATE fails SILENTLY: with no UPDATE policy PostgREST
                // matches 0 rows and returns success, so asserting on a thrown
                // exception proves nothing. The real assertion is that the row
                // is UNTOUCHED afterwards — the same trap `BillingWebhookTests`
                // documents, and which this file walked straight into on its
                // first CI run.
                var hijack = mine;
                hijack.Cycle = "annual";
                hijack.PriceCents = 1;
                try { await fx.Founder.From<Subscription>().Update(hijack); }
                catch { /* an error here is equally acceptable */ }

                var after = (await fx.Service.From<Subscription>()
                    .Filter("id", Constants.Operator.Equals, row.Id)
                    .Get()).Models!.Single();
                Assert.Equal("monthly", after.Cycle);
                Assert.Equal(690, after.PriceCents);
            }
            finally
            {
                await ClearSubscriptionAsync(fx.FamilyId);
            }
        }

        [Fact] // The store switch is public (the client mirrors it) and starts
               // OFF — an offer the store cannot honor is worse than no offer.
        public async Task TheStoreSwitchIsPublicAndStartsOff()
        {
            var settings = await fx.Founder.From<AppSetting>().Get();
            var row = settings.Models.SingleOrDefault(s => s.Key == "billing.store_enabled");

            Assert.NotNull(row);
            Assert.Equal("false", row!.Value);
        }

        [Fact] // The function runs without the platform's JWT gate (S-16), so
               // its own session check is the whole door.
        public async Task VerifyRefusesAnAnonymousCaller()
        {
            using var http = new HttpClient();
            using var request = new HttpRequestMessage(HttpMethod.Post, VerifyUrl)
            {
                Content = new StringContent(
                    JsonSerializer.Serialize(new
                    {
                        product_id = "premium_monthly",
                        purchase_token = "forged",
                    }),
                    Encoding.UTF8, "application/json"),
            };
            request.Headers.Add("apikey", TestEnv.AnonKey);

            using var response = await http.SendAsync(request);

            Assert.Equal(HttpStatusCode.Unauthorized, response.StatusCode);
        }
    }
}
