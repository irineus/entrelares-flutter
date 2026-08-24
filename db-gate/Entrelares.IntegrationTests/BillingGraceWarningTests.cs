using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // S-15/B-3 — billing_grace_warnings_due().
    //
    // PR3a published "Avisaremos por e-mail antes da indisponibilidade" in the
    // Terms. Nothing implemented it: billing_grace_downgrade (T-39 PR3) flipped the
    // plan in silence. These tests are what make the sentence true, and they care
    // most about the two ways a warning goes wrong — never arriving, or arriving
    // over and over.
    //
    // Defaults assumed: billing.grace_days = 7, billing.grace_warning_days = 2, so
    // the window is [overdue_since + 5d, overdue_since + 7d).
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class BillingGraceWarningTests(E2EFamilyFixture fx)
    {
        private async Task<Subscription> SeedOverdueAsync(long familyId, string tag, int overdueDaysAgo)
        {
            await fx.DeleteSubscriptionSeedAsync($"sub_e2e_{tag}");
            var seeded = (await fx.Service.From<Subscription>().Insert(new Subscription
            {
                FamilyId = familyId,
                ExternalSubscriptionId = $"sub_e2e_{tag}",
                Cycle = "monthly",
                PriceCents = 1490
            })).Models!.Single();

            seeded.Status = "overdue";
            seeded.OverdueSince = DateTime.UtcNow.AddDays(-overdueDaysAgo);
            var saved = (await fx.Service.From<Subscription>().Update(seeded)).Models!.Single();

            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId,
                ["p_plan"] = "premium"
            });
            return saved;
        }

        private Task WarnAsync() =>
            fx.Service.Rpc("billing_grace_warnings_due", new Dictionary<string, object>());

        private async Task<Subscription> ReloadAsync(long id) =>
            (await fx.Service.From<Subscription>().Where(s => s.Id == id).Get()).Models!.Single();

        private async Task<List<AppNotification>> BillingNoticesAsync(long profileId) =>
            (await fx.Service.From<AppNotification>()
                .Where(n => n.RecipientProfileId == profileId)
                .Where(n => n.Type == "billing").Get()).Models!;

        [Fact] // Inside the window: the admin is warned, in-app and by marker.
        public async Task InsideWindow_WarnsTheAdmin_AndStamps()
        {
            var fam = await fx.CreateFamilyAsync("gw1");
            var sub = await SeedOverdueAsync(fam.FamilyId, "gw1", overdueDaysAgo: 6);

            await WarnAsync();

            Assert.NotNull((await ReloadAsync(sub.Id)).GraceWarningSentAt);

            // The in-app notice is the RELIABLE channel — written by the RPC in the
            // same transaction as the marker, so it survives a Resend outage.
            var notices = await BillingNoticesAsync(fam.AdminProfile.Id);
            Assert.Single(notices);
            Assert.Contains("Plano Gratuito", notices[0].Message);
        }

        [Fact] // Only ADMINS. A member who cannot reach the checkout must not get an
               // alarm they have no way to answer (F-40/T-39: billing is admin-only).
        public async Task InsideWindow_DoesNotWarnNonAdminMembers()
        {
            var fam = await fx.CreateFamilyAsync("gw2");
            await SeedOverdueAsync(fam.FamilyId, "gw2", overdueDaysAgo: 6);

            await WarnAsync();

            Assert.Empty(await BillingNoticesAsync(fam.MemberProfile.Id));
        }

        [Fact] // Idempotent. The cron runs daily and the window is two days wide, so
               // without the marker the same family would be warned every run.
        public async Task SecondRun_DoesNotWarnAgain()
        {
            var fam = await fx.CreateFamilyAsync("gw3");
            await SeedOverdueAsync(fam.FamilyId, "gw3", overdueDaysAgo: 6);

            await WarnAsync();
            await WarnAsync();
            await WarnAsync();

            Assert.Single(await BillingNoticesAsync(fam.AdminProfile.Id));
        }

        [Fact] // Too early: warning on day 1 of a 7-day grace would be alarmist and
               // would burn the single notice long before it is useful.
        public async Task BeforeWindow_DoesNotWarn()
        {
            var fam = await fx.CreateFamilyAsync("gw4");
            var sub = await SeedOverdueAsync(fam.FamilyId, "gw4", overdueDaysAgo: 1);

            await WarnAsync();

            Assert.Null((await ReloadAsync(sub.Id)).GraceWarningSentAt);
            Assert.Empty(await BillingNoticesAsync(fam.AdminProfile.Id));
        }

        [Fact] // Too late: past the downgrade there is nothing to warn ABOUT — the
               // access is already gone, and "avisaremos ANTES" would be a lie.
        public async Task AfterGraceExpired_DoesNotWarn()
        {
            var fam = await fx.CreateFamilyAsync("gw5");
            var sub = await SeedOverdueAsync(fam.FamilyId, "gw5", overdueDaysAgo: 9);

            await WarnAsync();

            Assert.Null((await ReloadAsync(sub.Id)).GraceWarningSentAt);
            Assert.Empty(await BillingNoticesAsync(fam.AdminProfile.Id));
        }

        [Fact] // A NEW overdue cycle re-arms the warning. Without the reset trigger a
               // family warned once would go silent forever: it pays, falls overdue
               // months later, and the stale marker suppresses the second warning.
        public async Task NewOverdueCycle_ResetsTheMarker()
        {
            var fam = await fx.CreateFamilyAsync("gw6");
            var sub = await SeedOverdueAsync(fam.FamilyId, "gw6", overdueDaysAgo: 6);

            await WarnAsync();
            Assert.NotNull((await ReloadAsync(sub.Id)).GraceWarningSentAt);

            // The webhook stamping a fresh overdue_since is what starts a new cycle.
            await fx.Service.From<Subscription>()
                .Where(s => s.Id == sub.Id)
                .Set(s => s.OverdueSince!, DateTime.UtcNow.AddDays(-6).AddMinutes(-1))
                .Update();

            Assert.Null((await ReloadAsync(sub.Id)).GraceWarningSentAt);

            await WarnAsync();
            Assert.Equal(2, (await BillingNoticesAsync(fam.AdminProfile.Id)).Count);
        }

        [Fact] // Service-role only — it writes notifications for other people.
        public async Task Warn_IsRefused_ForAuthenticatedCaller()
        {
            var fam = await fx.CreateFamilyAsync("gw7");

            await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("billing_grace_warnings_due", new Dictionary<string, object>()));
        }
    }
}
