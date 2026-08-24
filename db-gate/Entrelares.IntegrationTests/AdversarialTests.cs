using Entrelares.Models;
using Supabase.Postgrest;

namespace Entrelares.IntegrationTests
{
    // T-32 (Suite E) — negative / adversarial exploration: probe how the app
    // FAILS. Every scenario forges a payload or composes two allowed operations
    // to reach a forbidden state; all must be rejected by the DATABASE (RLS or
    // a trigger), never by the UI alone — that is the invariant an attacker who
    // hits PostgREST directly cannot evade. Destructive scenarios run on
    // throwaway families.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class AdversarialTests(E2EFamilyFixture fx)
    {
        private static async Task AssertRejectedAsync(Func<Task> action, string? messagePart = null)
        {
            var ex = await Assert.ThrowsAnyAsync<Exception>(action);
            if (messagePart is not null) Assert.Contains(messagePart, ex.Message);
        }

        // ── Forged writes to the S-11 PR2 consent tables (SELECT-only RLS) ───────

        [Fact] // A member cannot forge a family-deletion REQUEST outside the RPC.
        public async Task ForgedFamilyDeletionRequest_IsBlocked()
        {
            await AssertRejectedAsync(() => fx.Member.From<FamilyDeletionRequest>().Insert(
                new FamilyDeletionRequest
                {
                    FamilyId = fx.FamilyId,
                    RequestedBy = fx.MemberProfile.Id,
                    ScheduledFor = DateTime.UtcNow.AddDays(30),
                    Status = "pending"
                }));

            var forged = (await fx.Service.From<FamilyDeletionRequest>()
                .Where(r => r.FamilyId == fx.FamilyId).Get()).Models!;
            Assert.Empty(forged);
        }

        [Fact] // A member cannot fabricate another member's CONSENT row directly.
        public async Task ForgedFamilyDeletionResponse_IsBlocked()
        {
            var fam = await fx.CreateFamilyAsync("adv-consent");
            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());
            var req = (await fam.Admin.From<FamilyDeletionRequest>().Get()).Models!
                .Single(r => r.Status == "pending");

            // The requester tries to stamp the member's agreement themselves.
            await AssertRejectedAsync(() => fam.Admin.From<FamilyDeletionResponse>().Insert(
                new FamilyDeletionResponse
                {
                    RequestId = req.Id,
                    ProfileId = fam.MemberProfile.Id,
                    Agreed = true
                }));

            Assert.Empty((await fx.Service.From<FamilyDeletionResponse>()
                .Where(r => r.RequestId == req.Id).Get()).Models!);
        }

        // ── RPC guards with no pending request ───────────────────────────────────

        [Fact] // execute/respond without a pending request → PT-BR rejection.
        public async Task FamilyDeletionRpcs_WithoutPendingRequest_AreRejected()
        {
            var fam = await fx.CreateFamilyAsync("adv-nopending");

            await fx.ElevateAsync(fam.AdminProfile);
            await AssertRejectedAsync(
                () => fam.Admin.Rpc("execute_family_deletion", new Dictionary<string, object>()),
                "Não há solicitação");

            await AssertRejectedAsync(
                () => fam.Member.Rpc("respond_family_deletion", new Dictionary<string, object> { ["p_agree"] = true }),
                "Não há solicitação");
        }

        // ── Cross-family notification spam ───────────────────────────────────────

        [Fact] // RLS WITH CHECK ties a notification to the caller's family — a
               // member of family A cannot insert one targeting family B.
        public async Task CrossFamilyNotificationInsert_IsBlocked()
        {
            var marker = $"adv-notif-{Guid.NewGuid():N}";
            await AssertRejectedAsync(() => fx.Founder.From<AppNotification>().Insert(
                new AppNotification
                {
                    RecipientProfileId = fx.FounderBProfile.Id,   // other family
                    Type = "swap_requested",
                    Title = "forjado",
                    Message = marker,
                    IsRead = false,
                    CreatedAt = DateTime.UtcNow
                }, new QueryOptions { Returning = QueryOptions.ReturnType.Minimal }));

            Assert.Empty((await fx.Service.From<AppNotification>()
                .Where(n => n.Message == marker).Get()).Models!);
        }

        // ── Double-submit / replay of a resolved swap ────────────────────────────

        [Fact] // Approving an already-resolved swap is rejected — the status
               // transition trigger makes double-submit idempotent.
        public async Task ReplayingResolvedSwap_IsRejected()
        {
            var fam = await fx.CreateFamilyAsync("adv-replay");
            var date = DateOnly.FromDateTime(DateTime.Today).AddDays(26);
            var schedule = (await fam.Admin.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fam.AdminProfile.Id
            })).Models!.First();

            // Admin requests a swap proposing the member (same INSERT the client
            // does); the member is the target and approves it.
            var req = (await fam.Admin.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                ScheduleId = schedule.Id,
                RequestingProfileId = fam.AdminProfile.Id,
                TargetProfileId = fam.MemberProfile.Id,
                ProposedActualParentId = fam.MemberProfile.Id,
                ProposedHandoffTime = new TimeOnly(12, 0),
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            })).Models!.First();

            req.Status = "approved";
            await fam.Member.From<SwapRequest>().Update(req);

            // Replay: any CHANGE out of the resolved 'approved' status is rejected
            // (approved→rejected and approved→pending both hit the trigger's ELSE).
            // Note: re-writing the SAME status is legitimately allowed (the trigger
            // short-circuits OLD.status = NEW.status, e.g. to stamp reminder_sent_at),
            // so double-submit only matters when it tries to CHANGE the outcome.
            var reload = (await fam.Member.From<SwapRequest>()
                .Where(r => r.Id == req.Id).Get()).Models!.Single();
            reload.Status = "rejected";
            await AssertRejectedAsync(() => fam.Member.From<SwapRequest>().Update(reload), "transition");

            reload = (await fam.Member.From<SwapRequest>()
                .Where(r => r.Id == req.Id).Get()).Models!.Single();
            reload.Status = "pending";
            await AssertRejectedAsync(() => fam.Member.From<SwapRequest>().Update(reload), "transition");

            // The request stayed 'approved' throughout.
            var final = (await fx.Service.From<SwapRequest>()
                .Where(r => r.Id == req.Id).Get()).Models!.Single();
            Assert.Equal("approved", final.Status);
        }

        // ── Compose-two-operations: leave + cancel loop keeps state clean ────────

        [Fact] // Repeated leave→cancel cycles must not corrupt the color slot,
               // duplicate the profile, or lose the seat (S-11 QA color slots).
        public async Task LeaveCancelLoop_KeepsColorSlotAndSeat_NoDuplication()
        {
            var fam = await fx.CreateFamilyAsync("adv-loop");
            var originalSlot = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.MemberProfile.Id).Get()).Models!.Single().ColorSlot;

            for (var cycle = 0; cycle < 2; cycle++)
            {
                await fx.ElevateAsync(fam.MemberProfile);
                await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());
                await fx.ElevateAsync(fam.MemberProfile);
                await fam.Member.Rpc("cancel_account_deletion", new Dictionary<string, object>());
            }

            var rows = (await fx.Service.From<Profile>()
                .Where(p => p.FamilyId == fam.FamilyId).Get()).Models!;
            // Exactly one profile per member — no duplication across the cycles.
            Assert.Single(rows, p => p.Id == fam.MemberProfile.Id);
            var member = rows.Single(p => p.Id == fam.MemberProfile.Id);
            Assert.True(member.IsActiveMember);            // back and active
            Assert.Null(member.LeftAt);
            Assert.Equal(originalSlot, member.ColorSlot);  // color slot preserved
        }

        // ── Frozen day (pending swap) is untouchable by a regular member ─────────

        [Fact] // Compose: create a pending swap (freezes the day), then try to
               // DELETE the day as a regular member → blocked by the frozen guard.
        public async Task FrozenDay_CannotBeDeletedByRegularMember()
        {
            var fam = await fx.CreateFamilyAsync("adv-frozen");
            var date = DateOnly.FromDateTime(DateTime.Today).AddDays(28);
            var schedule = (await fam.Admin.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fam.AdminProfile.Id
            })).Models!.First();

            // Member requests a swap on this day → the day is now frozen.
            await fam.Member.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = date,
                ScheduleId = schedule.Id,
                RequestingProfileId = fam.MemberProfile.Id,
                TargetProfileId = fam.AdminProfile.Id,
                ProposedActualParentId = fam.MemberProfile.Id,
                ProposedHandoffTime = new TimeOnly(9, 0),
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            });

            // Requesting member tries to delete the frozen day → rejected.
            await AssertRejectedAsync(
                () => fam.Member.From<CareSchedule>().Where(s => s.Id == schedule.Id).Delete(),
                "solicitação pendente");

            Assert.Single((await fx.Service.From<CareSchedule>()
                .Where(s => s.Id == schedule.Id).Get()).Models!);
        }

        // ── Boundary: 100-char notes round-trip intact ───────────────────────────

        [Fact] // A 100-char note (the UI's maxlength) survives the round-trip
               // byte-for-byte. The DB column is `text` with NO length limit —
               // the 100-char cap is UI-only (documented, accepted).
        public async Task NotesAt100Chars_RoundTripIntact()
        {
            var fam = await fx.CreateFamilyAsync("adv-notes");
            var date = DateOnly.FromDateTime(DateTime.Today).AddDays(29);
            var note = new string('á', 50) + new string('x', 50);   // 100 chars, accented

            await fam.Admin.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fam.AdminProfile.Id,
                Notes = note
            });

            var stored = (await fam.Admin.From<CareSchedule>()
                .Where(s => s.ScheduleDate == date).Get()).Models!.Single();
            Assert.Equal(note, stored.Notes);
            Assert.Equal(100, stored.Notes!.Length);
        }

        // ── Concurrency token cannot be stamped to an unread value ───────────────

        [Fact] // T-33: a client update carrying a revision it never read (here a
               // deliberately advanced value) is rejected — the honest-client
               // guard holds. (The monotonic-counter limitation is documented as
               // F-32-1 / T-35; no invariant is broken either way.)
        public async Task StampingUnreadRevision_IsRejected()
        {
            var fam = await fx.CreateFamilyAsync("adv-rev");
            var date = DateOnly.FromDateTime(DateTime.Today).AddDays(27);
            await fam.Admin.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = date,
                ScheduledParentId = fam.AdminProfile.Id
            });

            var day = (await fam.Admin.From<CareSchedule>()
                .Where(s => s.ScheduleDate == date).Get()).Models!.Single();

            day.Notes = "adv revision";
            day.Revision += 50;   // a value this client never legitimately reached
            await AssertRejectedAsync(
                () => fam.Admin.From<CareSchedule>().Update(day),
                "salvou este dia primeiro");
        }

        // ── S-14: cross-family isolation after dropping the always-true policies ──
        // Each probe seeds a row in family B and proves family A can neither read
        // nor mutate it. Before the S-14 migration the legacy `USING (true)`
        // policies made every one of these leak; the family-scoped policies now
        // stand alone.

        [Fact] // Family A cannot READ family B's calendar.
        public async Task CrossFamilyCareSchedule_IsNotReadable()
        {
            var day = fx.NextFutureDate();
            await fx.FounderB.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = day,
                ScheduledParentId = fx.FounderBProfile.Id
            });

            // Unique date, family A wrote nothing there → after S-14 it sees zero.
            var seenByA = (await fx.Founder.From<CareSchedule>()
                .Where(s => s.ScheduleDate == day).Get()).Models ?? [];
            Assert.Empty(seenByA);
        }

        [Fact] // Family A cannot DELETE (or otherwise mutate) family B's calendar.
        public async Task CrossFamilyCareSchedule_IsNotDeletable()
        {
            var day = fx.NextFutureDate();
            var rowB = (await fx.FounderB.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = day,
                ScheduledParentId = fx.FounderBProfile.Id
            })).Models!.Single();

            // RLS filters the delete to zero rows — no error, but nothing happens.
            await fx.Founder.From<CareSchedule>().Where(s => s.Id == rowB.Id).Delete();

            var stillThere = (await fx.Service.From<CareSchedule>()
                .Where(s => s.Id == rowB.Id).Get()).Models!.SingleOrDefault();
            Assert.NotNull(stillThere);
        }

        [Fact] // Family A cannot READ family B's immutable audit history.
        public async Task CrossFamilyAuditLog_IsNotReadable()
        {
            var day = fx.NextFutureDate();
            var schedB = (await fx.FounderB.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = day,
                ScheduledParentId = fx.FounderBProfile.Id
            })).Models!.Single();

            // The insert trigger wrote a family-B audit row; find it via service.
            var logB = (await fx.Service.From<ActivityLog>()
                .Where(l => l.ScheduleId == schedB.Id).Get()).Models!.First();

            var seenByA = (await fx.Founder.From<ActivityLog>().Get()).Models ?? [];
            Assert.DoesNotContain(seenByA, l => l.Id == logB.Id);
        }

        [Fact] // Family A cannot READ family B's profiles (names, e-mails, roles) —
               // while still seeing its OWN family (guards against over-restriction).
        public async Task CrossFamilyProfiles_AreNotReadable()
        {
            var seenByA = (await fx.Founder.From<Profile>().Get()).Models ?? [];

            Assert.DoesNotContain(seenByA, p => p.Id == fx.FounderBProfile.Id);
            Assert.Contains(seenByA, p => p.Id == fx.FounderProfile.Id);
        }
    }
}
