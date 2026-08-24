using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // T-31 Suite C (integration) — F-24 auto-approval. The Edge Function is a
    // thin wrapper over the auto_approve_expired() RPC (the real logic); these
    // call the RPC directly through the service client — deterministic, no
    // e-mails, no clock waiting. Requests are seeded with a backdated
    // schedule_date so their handoff expiry is a controlled number of hours in
    // the past (system context bypasses the day-protection trigger).
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class AutoApprovalTests(E2EFamilyFixture fx)
    {
        // The RPC computes expiry as schedule_date + handoff in America/Sao_Paulo
        // (fixed UTC-3). Build a schedule_date/handoff whose expiry is `hoursAgo`
        // in the past, so we land precisely in the reminder (24–48h) or
        // auto-approve (>48h) window regardless of wall-clock time.
        private static (DateOnly date, TimeOnly handoff) ExpiryHoursAgo(double hoursAgo)
        {
            var expirySp = DateTime.UtcNow.AddHours(-3).AddHours(-hoursAgo);
            return (DateOnly.FromDateTime(expirySp), TimeOnly.FromDateTime(expirySp));
        }

        private async Task<long> SeedPendingSwapAsync(double expiryHoursAgo)
        {
            var (date, handoff) = ExpiryHoursAgo(expiryHoursAgo);

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
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            return request.Id;
        }

        private async Task<SwapRequest> ReloadRequestAsync(long id) =>
            (await fx.Service.From<SwapRequest>().Where(r => r.Id == id).Get()).Models!.Single();

        [Fact] // C6 — a request expired > 48h is auto-approved as 'system' and the
               // calendar change is applied, exactly like a manual approval.
        public async Task ExpiredOver48h_IsAutoApprovedAsSystem()
        {
            var requestId = await SeedPendingSwapAsync(expiryHoursAgo: 60);

            await fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

            var request = await ReloadRequestAsync(requestId);
            Assert.Equal("approved", request.Status);
            Assert.Equal("system", request.ResolvedBy);

            var schedule = (await fx.Service.From<CareSchedule>()
                .Where(s => s.Id == request.ScheduleId!.Value)
                .Get()).Models!.Single();
            Assert.Equal(fx.MemberProfile.Id, schedule.ActualParentId);
        }

        [Fact] // C6b — a request expired between 24h and 48h gets a reminder
               // (reminder_sent_at set) but is NOT yet approved.
        public async Task ExpiredBetween24And48h_GetsReminderButNotApproved()
        {
            var requestId = await SeedPendingSwapAsync(expiryHoursAgo: 36);

            await fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

            var request = await ReloadRequestAsync(requestId);
            Assert.Equal("pending", request.Status);
            Assert.NotNull(request.ReminderSentAt);

            // U-13: the reminder's render payload is asserted HERE rather than in
            // NotificationParamsTests. The reminder only fires 24–48h before now,
            // a window barely two calendar days wide that this suite's 36h and 60h
            // cases already occupy — a second suite adding its own seed there
            // lands within 24h of one of them and collides on
            // (family_id, schedule_date). Asserting on an existing seed is the
            // only stable place for it.
            var reminder = (await fx.Service.From<AppNotification>()
                .Where(n => n.SwapRequestId == requestId)
                .Filter("type", Supabase.Postgrest.Constants.Operator.Equals, "auto_reminder")
                .Get()).Models!.Single();

            Assert.False(string.IsNullOrWhiteSpace(reminder.ParamsJson),
                "The reminder was written without params — the client cannot localize it.");
            // U-24: `params.date` is ISO 8601, NOT a formatted date. That is the whole
            // point — the reader's device decides how the day is written, so an English
            // reader is not shown `05/08` and told the wrong month. The PT-BR sentence
            // in `message` keeps its own format, as the fallback record of what was sent.
            Assert.Contains(request.ScheduleDate.ToString("yyyy-MM-dd"), reminder.ParamsJson!);
        }

        [Fact] // F-28 — auto-approval notifies the UNINVOLVED caregiver with an
               // explicit-name family-info message (in-app fan-out).
        public async Task AutoApproval_FansOutToUninvolvedCaregiver()
        {
            var third = await fx.EnsureThirdMemberAsync();   // requester=member, target=founder → third is uninvolved
            // 84h (not 60h like C6): a full day away, so the backdated
            // schedule_date never collides with C6's UNIQUE (family, date) row.
            var requestId = await SeedPendingSwapAsync(expiryHoursAgo: 84);

            await fx.Service.Rpc("auto_approve_expired", new Dictionary<string, object>
            {
                ["p_env_prefix"] = "[Dev] "
            });

            var info = (await fx.Service.From<AppNotification>()
                .Where(n => n.SwapRequestId == requestId)
                .Filter("type", Supabase.Postgrest.Constants.Operator.Equals, "swap_family_info")
                .Get()).Models!.Single();

            Assert.Equal(third.Id, info.RecipientProfileId);
            // Explicit name — the day lands on the proposed parent (the member).
            Assert.Contains(fx.MemberProfile.FullName, info.Message);
        }
    }
}
