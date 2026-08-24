using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-45 — swap_requests.resolution_log_id: the DB trigger stamps, on the
    // resolution transition, the activity_logs row the resolution produced —
    // closing the request → change link the Histórico and the PDF read.
    //
    // Like HandoffTransitionTests, these drive the REAL write paths: the manual
    // approval exactly as SwapRequestService.ApproveAsync issues it (target
    // updates care_schedules, then flips the request status) and the automatic
    // path through the auto_approve_expired RPC. A single trigger serves both,
    // which is the point of doing it server-side.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class ResolutionLogLinkTests(E2EFamilyFixture fx)
    {
        /// <summary>
        /// `created_at` for a seeded request, deliberately a minute in the past.
        ///
        /// <para><b>Why not simply <c>UtcNow</c>.</b> The trigger finds the
        /// resolution's audit row with <c>al.created_at &gt;= OLD.created_at</c>,
        /// where the left side is the DATABASE's clock and the right side is
        /// whatever the client wrote. `UtcNow` therefore made the test depend on
        /// the developer's workstation being no further ahead than the Supabase
        /// host — and a machine one second fast fails all four, with an
        /// <c>Assert.NotNull</c> that points at the trigger and says nothing about
        /// clocks. Found in the pre-production round of Aug 2026 on a box running
        /// ~1s fast; CI never saw it because CI runners are NTP-tight.</para>
        ///
        /// <para>A minute is far more than any plausible skew and changes nothing
        /// else: nothing here asserts on age, and the auto-approval window is
        /// 48h. The real app never had the problem — its requests are created and
        /// resolved by separate human acts, minutes or days apart — which is why
        /// this is a fix to the SEED and not to the trigger.</para>
        /// </summary>
        private static DateTime SeedCreatedAt => DateTime.UtcNow.AddMinutes(-1);

        private async Task<CareSchedule> SeedScheduleAsync(DateOnly date)
        {
            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fx.FounderProfile.Id
            });
            return (await fx.Founder.From<CareSchedule>()
                .Where(s => s.ScheduleDate == date).Get()).Models!.Single();
        }

        // The member asks for the founder's day — the founder is the approver,
        // which is what lets day protection accept the actual_parent change.
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
                CreatedAt = SeedCreatedAt,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

        // SwapRequestService.ApproveAsync, verbatim: the target applies the
        // calendar change with a full-row update, then resolves the request.
        private async Task ApplyAndResolveAsync(CareSchedule day, SwapRequest request, string status)
        {
            day.ActualParentId = request.ProposedActualParentId;
            day.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<CareSchedule>().Update(day);

            request.Status = status;
            request.ResolvedAt = DateTime.UtcNow;
            request.UpdatedAt = DateTime.UtcNow;
            await fx.Founder.From<SwapRequest>().Update(request);
        }

        private async Task<SwapRequest> ReloadAsync(long requestId) =>
            (await fx.Service.From<SwapRequest>().Where(r => r.Id == requestId).Get())
                .Models!.Single();

        private async Task<ActivityLog> LogAsync(long logId) =>
            (await fx.Service.From<ActivityLog>().Where(l => l.Id == logId).Get())
                .Models!.Single();

        [Fact] // Manual approval stamps the log the approver's calendar write produced.
        public async Task ManualApproval_StampsTheResolutionLog()
        {
            var date = fx.NextFutureDate();
            var day = await SeedScheduleAsync(date);
            var request = await OpenPendingSwapAsync(date, day.Id);

            await ApplyAndResolveAsync(day, request, "approved");

            var resolved = await ReloadAsync(request.Id);
            Assert.NotNull(resolved.ResolutionLogId);

            var log = await LogAsync(resolved.ResolutionLogId!.Value);
            Assert.Equal(date, DateOnly.FromDateTime(log.AffectedDate));
            Assert.Equal(day.Id, log.ScheduleId);
            Assert.Equal("UPDATE", log.Action);
        }

        [Fact] // The auto_approve_expired RPC goes through the same trigger — the
               // "Sistema" entry finally carries a trace of the request behind it.
        public async Task AutoApproval_StampsTheResolutionLog()
        {
            // 108h: same backdating technique as AutoApprovalTests, on a date
            // (~4.5 days ago) distinct from its 60h/84h seeds — the shared
            // family's UNIQUE (family_id, schedule_date) demands it.
            var expirySp = DateTime.UtcNow.AddHours(-3).AddHours(-108);
            var date = DateOnly.FromDateTime(expirySp);
            var handoff = TimeOnly.FromDateTime(expirySp);

            var schedule = (await fx.Service.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fx.FounderProfile.Id
            })).Models!.First();

            var request = (await fx.Service.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                ScheduleId = schedule.Id,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                PreviousActualParentId = null,
                ProposedActualParentId = fx.MemberProfile.Id,
                ProposedHandoffTime = handoff,
                Status = "pending",
                CreatedAt = SeedCreatedAt,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            await fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

            var resolved = await ReloadAsync(request.Id);
            Assert.Equal("approved", resolved.Status);
            Assert.Equal("system", resolved.ResolvedBy);
            Assert.NotNull(resolved.ResolutionLogId);

            var log = await LogAsync(resolved.ResolutionLogId!.Value);
            Assert.Equal(date, DateOnly.FromDateTime(log.AffectedDate));
            Assert.Equal(schedule.Id, log.ScheduleId);
        }

        [Fact] // A revert approval stamps its OWN resolution log — newer than the
               // original swap's, since the restore is a later calendar write.
        public async Task RevertApproval_StampsItsOwnNewerResolutionLog()
        {
            var date = fx.NextFutureDate();
            var day = await SeedScheduleAsync(date);
            var request = await OpenPendingSwapAsync(date, day.Id);
            await ApplyAndResolveAsync(day, request, "approved");
            var approvedLogId = (await ReloadAsync(request.Id)).ResolutionLogId;
            Assert.NotNull(approvedLogId);

            // RequestRevertAsync: the founder (planned parent) asks, so the
            // member — the currently approved parent — confirms and restores.
            var revert = (await fx.Founder.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                ScheduleId = day.Id,
                RequestingProfileId = fx.FounderProfile.Id,
                TargetProfileId = fx.MemberProfile.Id,
                PreviousActualParentId = fx.MemberProfile.Id,
                ProposedActualParentId = fx.FounderProfile.Id,
                Status = "revert_pending",
                CreatedAt = SeedCreatedAt,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            // ApproveRevertAsync without a pre-edit snapshot: clear the swap
            // back to the scheduled parent, then resolve.
            var toRestore = (await fx.Member.From<CareSchedule>()
                .Where(s => s.Id == day.Id).Get()).Models!.Single();
            toRestore.ActualParentId = null;
            toRestore.UpdatedAt = DateTime.UtcNow;
            await fx.Member.From<CareSchedule>().Update(toRestore);

            revert.Status = "revert_approved";
            revert.ResolvedAt = DateTime.UtcNow;
            revert.UpdatedAt = DateTime.UtcNow;
            await fx.Member.From<SwapRequest>().Update(revert);

            var resolvedRevert = await ReloadAsync(revert.Id);
            Assert.NotNull(resolvedRevert.ResolutionLogId);
            Assert.True(resolvedRevert.ResolutionLogId > approvedLogId,
                "the revert's resolution log must be the restore's write, not the original swap's");

            // The original swap's stamp survives the revert untouched.
            Assert.Equal(approvedLogId, (await ReloadAsync(request.Id)).ResolutionLogId);
        }

        [Fact] // The column is trigger-owned: a client full-row update on a
               // resolved request can neither clear nor forge the stamp.
        public async Task ClientWrite_CannotClearOrForgeTheStamp()
        {
            var date = fx.NextFutureDate();
            var day = await SeedScheduleAsync(date);
            var request = await OpenPendingSwapAsync(date, day.Id);
            await ApplyAndResolveAsync(day, request, "approved");

            var resolved = await ReloadAsync(request.Id);
            var stamped = resolved.ResolutionLogId;
            Assert.NotNull(stamped);

            // The requester rewrites the resolved row (status unchanged, so the
            // transition guard lets the update through) trying to null the link.
            resolved.ResolutionLogId = null;
            await fx.Member.From<SwapRequest>().Update(resolved);

            Assert.Equal(stamped, (await ReloadAsync(request.Id)).ResolutionLogId);
        }
    }
}
