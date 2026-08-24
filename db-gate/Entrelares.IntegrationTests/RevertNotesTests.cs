using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-47 — swap_requests.revert_notes: the requester decides whether undoing a
    // swap also puts the day's OBSERVATION back to the pre-swap snapshot.
    //
    // The decision is taken on one side and honoured on the other, so the two
    // things worth pinning in the database are exactly those: the 48h
    // auto-approval (which restores without any client involved) must read the
    // flag, and the approver — who rewrites the row when they resolve it —
    // must not be able to change the answer they were given.
    //
    // The manual approval path restores from C# (SwapRequestService.
    // RestorePreEditStateAsync); its half of the rule is covered by the unit
    // tests plus the QA pass, since no DB rule governs it.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class RevertNotesTests(E2EFamilyFixture fx)
    {
        private const string BeforeTheSwap = "F-47 texto A — combinado antes da troca";
        private const string AfterTheSwap  = "F-47 texto B — reescrito depois da troca";

        // Builds the situation the item exists for: a past day whose swap was
        // approved and whose observation was rewritten AFTERWARDS. Returns the
        // day and the activity_logs row whose old_data is the pre-swap
        // snapshot — the same reference RequestRevertAsync carries over.
        private async Task<(CareSchedule day, long preEditLogId)> SeedRewrittenObservationAsync(DateOnly date)
        {
            var day = (await fx.Service.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fx.FounderProfile.Id,
                Notes = BeforeTheSwap
            })).Models!.First();

            // The swap itself: this UPDATE's old_data IS the pre-edit snapshot.
            day.ActualParentId = fx.MemberProfile.Id;
            day.UpdatedAt = DateTime.UtcNow;
            await fx.Service.From<CareSchedule>().Update(day);

            // Newest log for this day, picked in memory (the day has two so far:
            // the INSERT and the swap UPDATE) — the swap's own row is the one
            // whose old_data holds the pre-swap observation.
            var preEditLog = (await fx.Service.From<ActivityLog>()
                .Where(l => l.ScheduleId == day.Id)
                .Get()).Models!.OrderByDescending(l => l.Id).First();

            // The family rewrites the observation days later — the text F-47
            // refuses to throw away behind their back.
            var rewritten = await ReadAsync(day.Id);
            rewritten.Notes = AfterTheSwap;
            rewritten.UpdatedAt = DateTime.UtcNow;
            await fx.Service.From<CareSchedule>().Update(rewritten);

            return (await ReadAsync(day.Id), preEditLog.Id);
        }

        // By id, never by date: the service client bypasses RLS, so a date
        // filter would also see other families' days.
        private async Task<CareSchedule> ReadAsync(long scheduleId) =>
            (await fx.Service.From<CareSchedule>()
                .Where(s => s.Id == scheduleId).Get()).Models!.Single();

        private async Task<SwapRequest> OpenExpiredRevertAsync(
            CareSchedule day, long preEditLogId, TimeOnly handoff, bool revertNotes) =>
            (await fx.Service.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = day.ScheduleDate,
                ScheduleId = day.Id,
                RequestingProfileId = fx.FounderProfile.Id,
                TargetProfileId = fx.MemberProfile.Id,
                PreviousActualParentId = fx.MemberProfile.Id,
                ProposedActualParentId = fx.FounderProfile.Id,
                ProposedHandoffTime = handoff,
                Status = "revert_pending",
                PreEditLogId = preEditLogId,
                RevertNotes = revertNotes,
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

        private Task RunAutoApprovalAsync() =>
            fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

        [Fact] // The default, and the answer a dismissed question leaves behind:
               // the swap is undone, the current observation survives it.
        public async Task AutoApproval_KeepsTheCurrentObservation_WhenTheRequesterDidNotAsk()
        {
            // ~16 days back, clear of the other backdated seeds (AutoApprovalTests
            // 60h/84h, ResolutionLogLinkTests 108h, HandoffTransitionTests 9d):
            // the RPC resolves every expired request in the project.
            var expirySp = DateTime.UtcNow.AddHours(-3).AddDays(-16);
            var (day, preEditLogId) = await SeedRewrittenObservationAsync(DateOnly.FromDateTime(expirySp));
            await OpenExpiredRevertAsync(day, preEditLogId, TimeOnly.FromDateTime(expirySp), revertNotes: false);

            await RunAutoApprovalAsync();

            var restored = await ReadAsync(day.Id);
            Assert.Null(restored.ActualParentId);              // the swap IS undone…
            Assert.Equal(AfterTheSwap, restored.Notes);        // …the observation is not.
        }

        [Fact] // The explicit opt-in: the requester asked for the old text back,
               // and the 48h path — which never saw the question — honours it.
        public async Task AutoApproval_RestoresTheObservation_WhenTheRequesterAskedForIt()
        {
            var expirySp = DateTime.UtcNow.AddHours(-3).AddDays(-17);
            var (day, preEditLogId) = await SeedRewrittenObservationAsync(DateOnly.FromDateTime(expirySp));
            await OpenExpiredRevertAsync(day, preEditLogId, TimeOnly.FromDateTime(expirySp), revertNotes: true);

            await RunAutoApprovalAsync();

            var restored = await ReadAsync(day.Id);
            Assert.Null(restored.ActualParentId);
            Assert.Equal(BeforeTheSwap, restored.Notes);
        }

        [Fact] // The choice belongs to the requester: the APPROVER rewrites this
               // row when they resolve it, and a flipped flag must not ride along.
        public async Task ApproverWrite_CannotFlipTheRequestersChoice()
        {
            var date = fx.NextFutureDate();
            var day = (await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fx.FounderProfile.Id,
                Notes = BeforeTheSwap
            })).Models!.First();

            // The founder asks to undo a swap on their own day and wants the
            // pre-swap observation back; the member is the approver.
            var revert = (await fx.Founder.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                ScheduleId = day.Id,
                RequestingProfileId = fx.FounderProfile.Id,
                TargetProfileId = fx.MemberProfile.Id,
                PreviousActualParentId = fx.MemberProfile.Id,
                ProposedActualParentId = fx.FounderProfile.Id,
                Status = "revert_pending",
                RevertNotes = true,
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            // Full-row update from the other side (status unchanged, so the
            // transition guard lets it through) carrying the opposite answer.
            revert.RevertNotes = false;
            await fx.Member.From<SwapRequest>().Update(revert);

            var reloaded = (await fx.Service.From<SwapRequest>()
                .Where(r => r.Id == revert.Id).Get()).Models!.Single();
            Assert.True(reloaded.RevertNotes);
        }

        [Fact] // Carried by the same migration: both worker functions were
               // reachable by any logged-in user. `REVOKE … FROM PUBLIC` (V007)
               // never removed Supabase's DEFAULT-PRIVILEGES grants to
               // anon/authenticated, so the lockdown had been inert since it was
               // written — restore_pre_edit_state is SECURITY DEFINER over a bare
               // schedule id, which made it a cross-family delete primitive.
        public async Task WorkerFunctions_AreNotCallableByAnEndUser()
        {
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.Rpc("auto_approve_expired", new Dictionary<string, object>
                {
                    ["p_env_prefix"] = "[Dev] "
                }));

            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.Rpc("restore_pre_edit_state", new Dictionary<string, object>
                {
                    ["p_schedule_id"] = 1,
                    ["p_pre_edit_log_id"] = 1,
                    ["p_restore_notes"] = false
                }));
        }
    }
}
