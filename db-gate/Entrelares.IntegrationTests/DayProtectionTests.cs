using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // Suite D — the day-protection rules live in the DATABASE (V008 + S-09);
    // these tests hit PostgREST directly, proving no UI shortcut can evade
    // them. Every expected failure asserts on the trigger's PT-BR message.
    [Collection("e2e-family")]
    public class DayProtectionTests(E2EFamilyFixture fx)
    {
        private async Task<CareSchedule> SeedDayAsync(Supabase.Client creator, long scheduledParentId, DateOnly? date = null)
        {
            var inserted = await creator.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date ?? fx.NextFutureDate(),
                ScheduledParentId = scheduledParentId
            });
            return inserted.Models!.First();
        }

        private static async Task AssertRejectedAsync(string expectedMessagePart, Func<Task> action)
        {
            var ex = await Assert.ThrowsAnyAsync<Exception>(action);
            Assert.Contains(expectedMessagePart, ex.Message);
        }

        [Fact] // S-09: the planned schedule is immutable for regular users.
        public async Task NonAdmin_CannotChangeScheduledParent_OfAssignedDay()
        {
            var day = await SeedDayAsync(fx.Founder, fx.FounderProfile.Id);

            day.ScheduledParentId = fx.MemberProfile.Id;
            await AssertRejectedAsync("responsável planejado só pode ser alterado",
                () => fx.Member.From<CareSchedule>().Update(day));
        }

        [Fact] // QA (July 2026): the delete + recreate bypass of S-09 is closed —
               // clearing an ASSIGNED day is admin-only; an admin still can.
        public async Task NonAdmin_CannotDeleteAssignedDay_AdminCan()
        {
            var day = await SeedDayAsync(fx.Founder, fx.FounderProfile.Id);

            // Regular member: delete rejected with the PT-BR message.
            await AssertRejectedAsync("só pode ser limpo por um administrador",
                () => fx.Member.From<CareSchedule>()
                    .Where(s => s.Id == day.Id)
                    .Delete());

            // The day survived intact.
            var still = (await fx.Member.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!;
            Assert.Single(still);

            // Admin (founder): delete allowed (F-14 bypass).
            await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id)
                .Delete();
            var gone = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!;
            Assert.Empty(gone);
        }

        [Fact] // F-12/S-05: creating a swap directly (actual ≠ scheduled) is workflow-only.
        public async Task NonAdmin_CannotSetActualParent_Directly_OnFutureDay()
        {
            var day = await SeedDayAsync(fx.Founder, fx.FounderProfile.Id);

            day.ActualParentId = fx.MemberProfile.Id;
            await AssertRejectedAsync("fluxo de aprovação",
                () => fx.Member.From<CareSchedule>().Update(day));
        }

        [Fact] // F-14 decision: on FUTURE days the workflow binds admins too.
        public async Task Admin_CannotSetActualParent_Directly_OnFutureDay()
        {
            var day = await SeedDayAsync(fx.Founder, fx.FounderProfile.Id);

            day.ActualParentId = fx.MemberProfile.Id;
            await AssertRejectedAsync("fluxo de aprovação",
                () => fx.Founder.From<CareSchedule>().Update(day));
        }

        [Fact] // F-13: past days are immutable for non-admins (seeded via service context).
        public async Task NonAdmin_CannotEdit_PastDay()
        {
            // The BAND is the point, not the randomness. `-3 - Next(1000)` starts
            // at today-3 — which is exactly the date AutoApprovalTests' 84h seed
            // computes — so a `Next` of 0 collided inside the SHARED family and
            // turned the whole gate red with a 23505 (07/08/2026, 1-in-1000 per
            // run). The randomisation was there to dodge collisions and instead
            // had one deterministic seed sitting on its floor.
            //
            // This test needs A past day, never a particular one, so it takes a
            // band no other seed can reach: the furthest deterministic past date
            // in the suite is 47 days (NotificationParamsTests), and the 220-day
            // one in AdminOverrideTierTests lives in a throwaway family.
            var pastDate = DateOnly.FromDateTime(DateTime.Today).AddDays(-400 - Random.Shared.Next(600));
            var day = await SeedDayAsync(fx.Service, fx.FounderProfile.Id, pastDate);

            day.Notes = "tentativa de edição";
            await AssertRejectedAsync("Dias passados",
                () => fx.Member.From<CareSchedule>().Update(day));
        }

        [Fact] // F-12: a day with a pending request is frozen for everyone but the target/admin.
        public async Task NonAdmin_CannotEdit_FrozenDay()
        {
            var day = await SeedDayAsync(fx.Founder, fx.FounderProfile.Id);

            // Member requests the swap (like SwapRequestService does), making
            // FOUNDER the target — the member is neither target nor admin.
            await fx.Member.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = day.ScheduleDate,
                ScheduleId = day.Id,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                Status = "pending"
            });

            day.Notes = "tentativa em dia congelado";
            await AssertRejectedAsync("solicitação pendente",
                () => fx.Member.From<CareSchedule>().Update(day));
        }

        [Fact] // F-12: an approved-swap day cannot be deleted by a regular user.
        public async Task NonAdmin_CannotDelete_ApprovedSwapDay()
        {
            // Approved swap = actual differs from scheduled (service context seeds it).
            var date = fx.NextFutureDate();
            await fx.Service.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fx.FounderProfile.Id,
                ActualParentId = fx.MemberProfile.Id
            });

            await AssertRejectedAsync("troca aprovada",
                () => fx.Member.From<CareSchedule>()
                    .Where(s => s.ScheduleDate == date)
                    .Delete());
        }
    }
}
