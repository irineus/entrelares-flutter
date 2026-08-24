using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-45 — the T-27 invariant as a DATABASE rule: a handoff time belongs only
    // on a TRANSITION day (one whose effective responsible differs from the
    // previous day's). Before this item the rule lived in the client and only
    // looked backwards on manual saves, so an approved swap on day D left D+1
    // with a handoff time on a day where nobody hands the child over — and a
    // revert could not put it back, because nothing recorded the removal.
    //
    // These tests exercise the real write paths (an approval applied by the
    // request's target, the auto_approve_expired RPC, the revert applied by the
    // revert's target), never a shortcut: the rule is worth nothing if it only
    // holds for the way the test writes.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class HandoffTransitionTests(E2EFamilyFixture fx)
    {
        private static readonly TimeOnly SixPm = new(18, 0);

        // Founder owns D, member owns D+1 at 18:00 — a genuine transition, so
        // the time survives the insert. Returns the two dates.
        private async Task<(DateOnly d, DateOnly next)> SeedTransitionPairAsync()
        {
            var dates = fx.NextFutureDates(2);

            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = dates[0],
                ScheduledParentId = fx.FounderProfile.Id
            });
            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = dates[1],
                ScheduledParentId = fx.MemberProfile.Id,
                HandoffTime = SixPm
            });

            Assert.Equal(SixPm, (await ReadAsync(dates[1])).HandoffTime);
            return (dates[0], dates[1]);
        }

        private async Task<CareSchedule> ReadAsync(DateOnly date) =>
            (await fx.Founder.From<CareSchedule>()
                .Where(s => s.ScheduleDate == date).Get()).Models!.Single();

        // The member asks for day D; the founder is the approver, which is what
        // lets the day-protection trigger accept the actual_parent change.
        private async Task<SwapRequest> OpenPendingSwapAsync(DateOnly date, long scheduleId) =>
            (await fx.Member.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                ScheduleId = scheduleId,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

        private async Task ResolveAsync(SwapRequest request, string status)
        {
            request.Status = status;
            request.ResolvedAt = DateTime.UtcNow;
            request.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<SwapRequest>().Update(request);
        }

        [Fact] // The gap the item was opened for: approving a swap on D makes D+1
               // stop being a transition, and its handoff time must go with it.
        public async Task Approval_ClearsTheHandoffOfANextDayThatStoppedBeingATransition()
        {
            var (d, next) = await SeedTransitionPairAsync();
            var day = await ReadAsync(d);
            var request = await OpenPendingSwapAsync(d, day.Id);

            // SwapRequestService.ApproveAsync, verbatim: the target applies the
            // calendar change with a full-row update.
            day = await ReadAsync(d);
            day.ActualParentId = fx.MemberProfile.Id;
            day.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<CareSchedule>().Update(day);
            await ResolveAsync(request, "approved");

            // D and D+1 are now both the member's: nobody hands over at 18:00.
            Assert.Null((await ReadAsync(next)).HandoffTime);
        }

        [Fact] // The other half: reverting the swap makes D+1 a transition again,
               // and the time the approval took away comes back — the parked
               // value, not a guess.
        public async Task Revert_GivesTheNextDaysHandoffBack()
        {
            var (d, next) = await SeedTransitionPairAsync();
            var day = await ReadAsync(d);
            var request = await OpenPendingSwapAsync(d, day.Id);

            day = await ReadAsync(d);
            day.ActualParentId = fx.MemberProfile.Id;
            day.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<CareSchedule>().Update(day);
            await ResolveAsync(request, "approved");
            Assert.Null((await ReadAsync(next)).HandoffTime);

            // RequestRevertAsync: the founder (the planned parent) asks, so the
            // approver — and the one who applies the restore — is the member.
            var revert = (await fx.Founder.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = d,
                ScheduleId = day.Id,
                RequestingProfileId = fx.FounderProfile.Id,
                TargetProfileId = fx.MemberProfile.Id,
                PreviousActualParentId = fx.MemberProfile.Id,
                ProposedActualParentId = fx.FounderProfile.Id,
                Status = "revert_pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            var toRestore = (await fx.Member.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            toRestore.ActualParentId = null;
            toRestore.UpdatedAt = DateTime.UtcNow;
            await fx.Member.From<CareSchedule>().Update(toRestore);

            revert.Status = "revert_approved";
            revert.ResolvedAt = DateTime.UtcNow;
            revert.UpdatedAt = DateTime.UtcNow;
            await fx.Member.From<SwapRequest>().Update(revert);

            Assert.Equal(SixPm, (await ReadAsync(next)).HandoffTime);
        }

        [Fact] // The server-side resolution path (F-24) goes through the same DB
               // rule — it is a trigger, not something ApproveAsync remembers to do.
        public async Task AutoApproval_ClearsTheNextDaysHandoff()
        {
            // Far enough in the past to be long expired, and far from the dates
            // AutoApprovalTests backdates (~2–4 days ago) — the RPC resolves every
            // expired request in the project, so the seeds must not overlap.
            var expirySp = DateTime.UtcNow.AddHours(-3).AddDays(-9);
            var d = DateOnly.FromDateTime(expirySp);
            var next = d.AddDays(1);

            var day = (await fx.Service.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = d,
                ScheduledParentId = fx.FounderProfile.Id
            })).Models!.First();
            var nextDay = (await fx.Service.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = next,
                ScheduledParentId = fx.MemberProfile.Id,
                HandoffTime = SixPm
            })).Models!.First();

            await fx.Service.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = d,
                ScheduleId = day.Id,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                ProposedHandoffTime = TimeOnly.FromDateTime(expirySp),
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            });

            await fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

            // By id, not by date: the service client bypasses RLS, so a date
            // filter would also pick up other families' days.
            var afterNext = (await fx.Service.From<CareSchedule>()
                .Where(s => s.Id == nextDay.Id).Get()).Models!.Single();
            Assert.Null(afterNext.HandoffTime);
        }

        [Fact] // The rule only removes what became meaningless: a D+1 that is
               // STILL a transition after the swap keeps its time. (The inverse
               // case — a swap that CREATES a transition at D+1 — is deliberately
               // left alone: there is no time to invent.)
        public async Task NextDayThatStaysATransition_KeepsItsHandoff()
        {
            var third = await fx.EnsureThirdMemberAsync();
            var dates = fx.NextFutureDates(2);

            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = dates[0],
                ScheduledParentId = fx.FounderProfile.Id
            });
            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = dates[1],
                ScheduledParentId = third.Id,
                HandoffTime = SixPm
            });

            var day = await ReadAsync(dates[0]);
            var request = await OpenPendingSwapAsync(dates[0], day.Id);

            day = await ReadAsync(dates[0]);
            day.ActualParentId = fx.MemberProfile.Id;   // founder → member, still ≠ third
            day.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<CareSchedule>().Update(day);
            await ResolveAsync(request, "approved");

            Assert.Equal(SixPm, (await ReadAsync(dates[1])).HandoffTime);
        }

        [Fact] // A time written by hand is INTENT and outranks whatever the rule
               // parked earlier: the revert must give back the time the family
               // last chose, never resurrect the one it replaced.
        public async Task ExplicitHandoffWrite_ReplacesTheParkedValue()
        {
            var (d, next) = await SeedTransitionPairAsync();
            var day = await ReadAsync(d);
            var request = await OpenPendingSwapAsync(d, day.Id);

            day = await ReadAsync(d);
            day.ActualParentId = fx.MemberProfile.Id;
            day.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<CareSchedule>().Update(day);
            await ResolveAsync(request, "approved");
            Assert.Null((await ReadAsync(next)).HandoffTime);

            // The family sets a NEW time on D+1 while it is not a transition —
            // the rule parks this one instead (it never lands on the day).
            var nextDay = await ReadAsync(next);
            nextDay.HandoffTime = new TimeOnly(20, 0);
            nextDay.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<CareSchedule>().Update(nextDay);
            Assert.Null((await ReadAsync(next)).HandoffTime);

            // Undo the swap: D+1 is a transition again and gets 20:00, not 18:00.
            var revert = (await fx.Founder.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = d,
                ScheduleId = day.Id,
                RequestingProfileId = fx.FounderProfile.Id,
                TargetProfileId = fx.MemberProfile.Id,
                PreviousActualParentId = fx.MemberProfile.Id,
                ProposedActualParentId = fx.FounderProfile.Id,
                Status = "revert_pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            var toRestore = (await fx.Member.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            toRestore.ActualParentId = null;
            toRestore.UpdatedAt = DateTime.UtcNow;
            await fx.Member.From<CareSchedule>().Update(toRestore);

            revert.Status = "revert_approved";
            revert.ResolvedAt = DateTime.UtcNow;
            revert.UpdatedAt = DateTime.UtcNow;
            await fx.Member.From<SwapRequest>().Update(revert);

            Assert.Equal(new TimeOnly(20, 0), (await ReadAsync(next)).HandoffTime);
        }
    }
}
