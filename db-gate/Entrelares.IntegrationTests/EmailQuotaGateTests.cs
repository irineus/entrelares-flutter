using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-38 — freemium gate: monthly transactional-e-mail cap. Free families get a
    // generous 100/month cap (per calendar month, America/Sao_Paulo); premium is
    // unlimited and never counted. consume_email_quota (called by send-swap-email)
    // returns a status and posts the in-app heads-ups: 80% ('email_cap_80'), the
    // last e-mail ('email_cap_last' — the warning e-mail takes the final slot), and
    // over-cap ('email_cap_reached'). Each fires once per month. The admin WARNING
    // e-mails are sent by the Edge Function (not covered here). In-app is never
    // capped. The counter is seeded near each threshold to avoid 100 real calls.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class EmailQuotaGateTests(E2EFamilyFixture fx)
    {
        private Task SetPlanAsync(long familyId, string plan) =>
            fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId,
                ["p_plan"] = plan
            });

        private async Task<string> ConsumeAsync(long familyId)
        {
            var resp = await fx.Service.Rpc("consume_email_quota", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId
            });
            return resp.Content ?? "";
        }

        private Task SeedCountAsync(long familyId, int count) =>
            fx.Service.From<EmailUsage>()
                .Where(e => e.FamilyId == familyId)
                .Set(e => e.SentCount, count)
                .Update();

        private async Task<int> InAppCountAsync(long recipientProfileId, string type)
        {
            var rows = (await fx.Service.From<AppNotification>()
                .Where(n => n.RecipientProfileId == recipientProfileId && n.Type == type)
                .Get()).Models ?? [];
            return rows.Count;
        }

        [Fact] // Free family: 80% + último heads-ups fire once each (with in-app), the
               // último warning takes the final slot, then over-cap denies; premium bypasses.
        public async Task FreeFamily_Milestones_FireOnce_ThenDenies()
        {
            var fam = await fx.CreateFamilyAsync("f38");
            await SetPlanAsync(fam.FamilyId, "free");
            var admin = fam.AdminProfile.Id;

            // Under every threshold: allowed, counter created.
            Assert.Contains("allowed", await ConsumeAsync(fam.FamilyId));

            // Crossing 80%: warn_80 + one in-app 'email_cap_80'.
            await SeedCountAsync(fam.FamilyId, 79);
            Assert.Contains("warn_80", await ConsumeAsync(fam.FamilyId));
            Assert.Equal(1, await InAppCountAsync(admin, "email_cap_80"));

            // Crossing the last slot (99): warn_last + one in-app 'email_cap_last';
            // the warning takes the final slot, so the counter is now at the cap.
            await SeedCountAsync(fam.FamilyId, 98);
            Assert.Contains("warn_last", await ConsumeAsync(fam.FamilyId));
            Assert.Equal(1, await InAppCountAsync(admin, "email_cap_last"));
            var row = (await fx.Service.From<EmailUsage>()
                .Where(e => e.FamilyId == fam.FamilyId).Get()).Models!.Single();
            Assert.Equal(100, row.SentCount);

            // Over the cap: denied + one in-app 'email_cap_reached'.
            Assert.Contains("denied", await ConsumeAsync(fam.FamilyId));
            Assert.Equal(1, await InAppCountAsync(admin, "email_cap_reached"));

            // Still denied — and no second over-cap notification (dedup).
            Assert.Contains("denied", await ConsumeAsync(fam.FamilyId));
            Assert.Equal(1, await InAppCountAsync(admin, "email_cap_reached"));

            // Premium bypasses the capped counter entirely.
            await SetPlanAsync(fam.FamilyId, "premium");
            Assert.Contains("allowed", await ConsumeAsync(fam.FamilyId));
        }

        [Fact] // Premium (trial) family: a HIGH anti-abuse cap, still counted — nothing
               // is truly unlimited — and none of the free-tier heads-ups fire.
        public async Task PremiumFamily_HasHighCap_AndIsCounted()
        {
            var fam = await fx.CreateFamilyAsync("f38-prem");   // premium via 30-day trial

            Assert.Contains("allowed", await ConsumeAsync(fam.FamilyId));

            // Premium is counted now (against email_cap_premium) — a usage row exists.
            var row = (await fx.Service.From<EmailUsage>()
                .Where(e => e.FamilyId == fam.FamilyId).Get()).Models!.Single();
            Assert.Equal(1, row.SentCount);

            // No free-tier conversion nudge for a premium family.
            Assert.Equal(0, await InAppCountAsync(fam.AdminProfile.Id, "email_cap_80"));
        }
    }
}
