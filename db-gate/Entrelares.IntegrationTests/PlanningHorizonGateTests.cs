using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-39 — freemium gate: planning horizon. Free families plan up to 6 months
    // ahead; premium up to 24, which is also the ABSOLUTE ceiling for everyone.
    // Enforced in the enforce_day_protection trigger (day-write path). Grandfather
    // is automatic (fresh families are premium during the 30-day trial), so the
    // free horizon is exercised by forcing plan = free via set_family_plan.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class PlanningHorizonGateTests(E2EFamilyFixture fx)
    {
        private Task SetPlanAsync(long familyId, string plan) =>
            fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId,
                ["p_plan"] = plan
            });

        private static async Task AssertRejectedAsync(string expectedMessagePart, Func<Task> action)
        {
            var ex = await Assert.ThrowsAnyAsync<Exception>(action);
            Assert.Contains(expectedMessagePart, ex.Message);
        }

        private Task InsertDayAsync(ThrowawayFamilyClient fam, int monthsAhead) =>
            fam.Client.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = DateOnly.FromDateTime(DateTime.Today.AddMonths(monthsAhead)),
                ScheduledParentId = fam.ProfileId
            });

        private readonly record struct ThrowawayFamilyClient(Supabase.Client Client, long ProfileId);

        [Fact] // Free family: a day within 6 months is allowed; beyond 6 is blocked.
        public async Task FreeFamily_BlockedBeyondSixMonths()
        {
            var fam = await fx.CreateFamilyAsync("f39-free");
            await SetPlanAsync(fam.FamilyId, "free");
            var admin = new ThrowawayFamilyClient(fam.Admin, fam.AdminProfile.Id);

            // 5 months ahead — comfortably inside the free horizon.
            await InsertDayAsync(admin, 5);

            // 7 months ahead — past the free horizon, refused with the upsell.
            await AssertRejectedAsync("Premium", () => InsertDayAsync(admin, 7));
        }

        [Fact] // Premium (trial) family: allowed to 24 months; everyone blocked past 24.
        public async Task PremiumFamily_AllowedTo24Months_BlockedBeyond()
        {
            var fam = await fx.CreateFamilyAsync("f39-prem");   // premium via 30-day trial
            var admin = new ThrowawayFamilyClient(fam.Admin, fam.AdminProfile.Id);

            // 12 months ahead — allowed on premium (would be blocked on free).
            await InsertDayAsync(admin, 12);

            // 25 months ahead — past the absolute 24-month ceiling, blocked for all.
            await AssertRejectedAsync("24 meses", () => InsertDayAsync(admin, 25));
        }
    }
}
