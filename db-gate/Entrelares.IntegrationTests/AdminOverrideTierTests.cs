using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-40 — Manager (Free) vs Administrator (Premium override). The retroactive
    // override of a PAST day is the premium power: a free admin (Gestor) fixes only
    // the last `override_free_days` (7); premium (Administrador) reaches back
    // `override_premium_months` (6), the hard cap for everyone. Enforced in the
    // enforce_day_protection past-day check. Frozen/planned-future/clear stay free
    // (unchanged). Fixture families are premium via trial, so the free window is
    // exercised by forcing plan = free.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class AdminOverrideTierTests(E2EFamilyFixture fx)
    {
        private Task SetPlanAsync(long familyId, string plan) =>
            fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId,
                ["p_plan"] = plan
            });

        // Seed a past day via service_role (bypasses the day-protection trigger).
        private async Task<DateOnly> SeedPastDayAsync(long scheduledParentId, int daysAgo)
        {
            var date = DateOnly.FromDateTime(DateTime.Today.AddDays(-daysAgo));
            await fx.Service.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = scheduledParentId
            });
            return date;
        }

        // A benign edit (notes) — fires the past-day check without touching S-09.
        private async Task EditNotesAsync(Supabase.Client client, DateOnly date, string notes)
        {
            var row = (await client.From<CareSchedule>()
                .Where(s => s.ScheduleDate == date).Get()).Models!.Single();
            row.Notes = notes;
            await client.From<CareSchedule>().Update(row);
        }

        [Fact] // Free admin (Gestor): corrects recent past days; blocked beyond the window.
        public async Task FreeAdmin_FixesRecentPast_BlockedBeyondWindow()
        {
            var fam = await fx.CreateFamilyAsync("f40-free");
            await SetPlanAsync(fam.FamilyId, "free");

            // 3 days ago — inside the 7-day free window → allowed.
            var recent = await SeedPastDayAsync(fam.AdminProfile.Id, 3);
            await EditNotesAsync(fam.Admin, recent, "corrigido");

            // 30 days ago — beyond the free window → blocked with the premium upsell.
            var old = await SeedPastDayAsync(fam.AdminProfile.Id, 30);
            var ex = await Assert.ThrowsAnyAsync<Exception>(() => EditNotesAsync(fam.Admin, old, "x"));
            Assert.Contains("Premium", ex.Message);
        }

        [Fact] // Administrador (Premium): corrects up to 6 months; blocked beyond the cap.
        public async Task PremiumAdmin_FixesUpToCap_BlockedBeyond()
        {
            var fam = await fx.CreateFamilyAsync("f40-prem");   // premium via 30-day trial

            // 30 days ago — well inside 6 months → allowed.
            var old = await SeedPastDayAsync(fam.AdminProfile.Id, 30);
            await EditNotesAsync(fam.Admin, old, "corrigido");

            // ~7 months ago — past the 6-month retroactive cap → blocked for everyone.
            var ancient = await SeedPastDayAsync(fam.AdminProfile.Id, 220);
            var ex = await Assert.ThrowsAnyAsync<Exception>(() => EditNotesAsync(fam.Admin, ancient, "x"));
            Assert.Contains("meses", ex.Message);
        }
    }
}
