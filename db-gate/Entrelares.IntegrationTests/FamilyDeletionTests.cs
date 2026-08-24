using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // S-11 (PR2) — whole-family deletion with multi-party consent:
    //   · admin-only + sudo-gated request; single pending request per family;
    //   · while pending: invitations and individual exits are BLOCKED;
    //   · any refusal ends the request at once (family continues); agreement is
    //     recorded but never accelerates the purge (the 30-day window always
    //     runs in full);
    //   · withdraw is requester-only + sudo; a new request restarts the window;
    //   · reminder fires ONCE at D-3; the purge past the window removes the
    //     whole family and hands back uids + real e-mails for the cron.
    // Destructive scenarios run on throwaway families so the shared fixture is
    // never mutated.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class FamilyDeletionTests(E2EFamilyFixture fx)
    {
        [Fact] // Non-admins cannot request; admins need a fresh elevation.
        public async Task RequestFamilyDeletion_Gates_AdminAndSudo()
        {
            var fam = await fx.CreateFamilyAsync("fdel-gate");

            // Non-admin, even elevated → rejected.
            await fx.ElevateAsync(fam.MemberProfile);
            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("request_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("administradores", ex.Message);

            // Admin without elevation → the detectable ELEVATION_REQUIRED contract.
            await fx.ClearElevationAsync(fam.AdminProfile);
            var ex2 = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("ELEVATION_REQUIRED", ex2.Message);

            // Nothing was created.
            var requests = (await fx.Service.From<FamilyDeletionRequest>()
                .Where(r => r.FamilyId == fam.FamilyId).Get()).Models!;
            Assert.Empty(requests);
        }

        [Fact] // Pending request: notifies members, blocks the concurrent flows,
               // records agreement without ending, and ends at once on refusal.
        public async Task PendingRequest_Notifies_Blocks_AgreeRecords_RefusalEnds()
        {
            var fam = await fx.CreateFamilyAsync("fdel-flow");

            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());

            // Pending and RLS-visible to the family; deadline ~30 days out.
            var pending = (await fam.Member.From<FamilyDeletionRequest>().Get()).Models!
                .Single(r => r.Status == "pending");
            Assert.Equal(fam.AdminProfile.Id, pending.RequestedBy);
            Assert.True(pending.ScheduledFor > DateTime.UtcNow.AddDays(29));

            // The other member was told in-app.
            var memberNotifs = (await fam.Member.From<AppNotification>().Get()).Models!;
            Assert.Contains(memberNotifs, n => n.Type == "family_deletion"
                && n.RecipientProfileId == fam.MemberProfile.Id);

            // A second request is blocked while one is pending.
            await fx.ElevateAsync(fam.AdminProfile);
            var exSecond = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("em andamento", exSecond.Message);

            // Invitations are blocked while pending.
            var exInvite = await Assert.ThrowsAnyAsync<Exception>(() =>
                E2EFamilyFixture.CreateInvitationAsync(fam.Admin, fx.TestEmail("fdel-inv"), fx.Roles.First().Id));
            Assert.Contains("bloqueados", exInvite.Message);

            // Individual exit is blocked while pending.
            await fx.ElevateAsync(fam.MemberProfile);
            var exExit = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>()));
            Assert.Contains("exclusão da família em andamento", exExit.Message);

            // Agreement is recorded but the request STAYS pending (full window).
            await fam.Member.Rpc("respond_family_deletion",
                new Dictionary<string, object> { ["p_agree"] = true });
            var agreed = (await fx.Service.From<FamilyDeletionResponse>()
                .Where(r => r.RequestId == pending.Id).Get()).Models!.Single();
            Assert.True(agreed.Agreed);
            var stillPending = (await fam.Member.From<FamilyDeletionRequest>().Get()).Models!
                .Single(r => r.Id == pending.Id);
            Assert.Equal("pending", stillPending.Status);

            // Changing the answer to a refusal ends the request immediately.
            await fam.Member.Rpc("respond_family_deletion",
                new Dictionary<string, object> { ["p_agree"] = false });
            var refused = (await fam.Member.From<FamilyDeletionRequest>().Get()).Models!
                .Single(r => r.Id == pending.Id);
            Assert.Equal("refused", refused.Status);
            Assert.Equal(fam.MemberProfile.Id, refused.ResolvedBy);

            // Everyone (requester included) learns the family continues.
            var adminNotifs = (await fam.Admin.From<AppNotification>().Get()).Models!;
            Assert.Contains(adminNotifs, n => n.Type == "family_deletion"
                && n.RecipientProfileId == fam.AdminProfile.Id
                && n.Message.Contains("recusou"));

            // With the request resolved, invitations flow again.
            var token = await E2EFamilyFixture.CreateInvitationAsync(
                fam.Admin, fx.TestEmail("fdel-inv2"), fx.Roles.First().Id);
            Assert.False(string.IsNullOrWhiteSpace(token));
        }

        [Fact] // Withdraw: requester-only + sudo; a new request restarts the window.
        public async Task Withdraw_RequesterOnly_Sudo_ThenNewRequestPossible()
        {
            var fam = await fx.CreateFamilyAsync("fdel-wdrw");

            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());

            // Another member cannot withdraw (they refuse instead).
            var exOther = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("withdraw_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("Somente quem solicitou", exOther.Message);

            // The requester needs a fresh elevation.
            await fx.ClearElevationAsync(fam.AdminProfile);
            var exSudo = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("withdraw_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("ELEVATION_REQUIRED", exSudo.Message);

            // Elevated → withdrawn, and a fresh request can be opened after.
            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("withdraw_family_deletion", new Dictionary<string, object>());
            var withdrawn = (await fam.Admin.From<FamilyDeletionRequest>().Get()).Models!
                .Single(r => r.Status == "withdrawn");
            Assert.Equal(fam.AdminProfile.Id, withdrawn.ResolvedBy);

            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());
            var reopened = (await fam.Admin.From<FamilyDeletionRequest>().Get()).Models!;
            Assert.Single(reopened, r => r.Status == "pending");
        }

        [Fact] // QA: undo (p_agree NULL) returns the member to "aguardando" —
               // the request survives, and the response row is gone.
        public async Task UndoAgreement_RemovesResponse_RequestStaysPending()
        {
            var fam = await fx.CreateFamilyAsync("fdel-undo");

            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());
            await fam.Member.Rpc("respond_family_deletion",
                new Dictionary<string, object> { ["p_agree"] = true });

            var pending = (await fam.Member.From<FamilyDeletionRequest>().Get()).Models!
                .Single(r => r.Status == "pending");
            Assert.Single((await fx.Service.From<FamilyDeletionResponse>()
                .Where(r => r.RequestId == pending.Id).Get()).Models!);

            await fam.Member.Rpc("respond_family_deletion",
                new Dictionary<string, object?> { ["p_agree"] = null });

            Assert.Empty((await fx.Service.From<FamilyDeletionResponse>()
                .Where(r => r.RequestId == pending.Id).Get()).Models!);
            var still = (await fam.Member.From<FamilyDeletionRequest>().Get()).Models!
                .Single(r => r.Id == pending.Id);
            Assert.Equal("pending", still.Status);
        }

        [Fact] // QA: immediate execution — admin + sudo + explicit unanimity; the
               // deadline jumps to NOW and the purge picks the family up at once.
        public async Task ExecuteFamilyDeletion_RequiresUnanimity_ThenPurgesImmediately()
        {
            var fam = await fx.CreateFamilyAsync("fdel-exec");

            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());

            // Without unanimity → rejected even elevated.
            await fx.ElevateAsync(fam.AdminProfile);
            var exNoConsent = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("execute_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("concordância explícita", exNoConsent.Message);

            // Member agrees → unanimity reached; non-admin still cannot execute.
            await fam.Member.Rpc("respond_family_deletion",
                new Dictionary<string, object> { ["p_agree"] = true });
            var exNonAdmin = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Member.Rpc("execute_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("administradores", exNonAdmin.Message);

            // Admin without a fresh elevation → ELEVATION_REQUIRED.
            await fx.ClearElevationAsync(fam.AdminProfile);
            var exSudo = await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("execute_family_deletion", new Dictionary<string, object>()));
            Assert.Contains("ELEVATION_REQUIRED", exSudo.Message);

            // Elevated → executes: deadline is NOW and the purge takes the family.
            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("execute_family_deletion", new Dictionary<string, object>());

            var result = await fx.Service.Rpc("purge_expired_family_deletions", new Dictionary<string, object>());
            Assert.Contains(fam.AdminProfile.UserId, result.Content ?? string.Empty);
            var families = (await fx.Service.From<Family>().Where(f => f.Id == fam.FamilyId).Get()).Models!;
            Assert.Empty(families);
        }

        [Fact] // The D-3 reminder fires exactly once and writes the in-app notices.
        public async Task Reminder_FiresOnce_AtDMinus3()
        {
            var fam = await fx.CreateFamilyAsync("fdel-rem");

            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());

            // Not due yet (deadline ~30 days out) → no reminder.
            await fx.Service.Rpc("family_deletion_reminders_due", new Dictionary<string, object>());
            var untouched = (await fx.Service.From<FamilyDeletionRequest>()
                .Where(r => r.FamilyId == fam.FamilyId).Get()).Models!.Single(r => r.Status == "pending");
            Assert.Null(untouched.ReminderSentAt);

            // Move the deadline to 2 days from now → inside the D-3 window.
            await fx.Service.From<FamilyDeletionRequest>()
                .Where(r => r.Id == untouched.Id)
                .Set(r => r.ScheduledFor, DateTime.UtcNow.AddDays(2))
                .Update();

            var due = await fx.Service.Rpc("family_deletion_reminders_due", new Dictionary<string, object>());
            Assert.Contains(fam.AdminProfile.Id.ToString(), due.Content ?? string.Empty);

            var marked = (await fx.Service.From<FamilyDeletionRequest>()
                .Where(r => r.Id == untouched.Id).Get()).Models!.Single();
            Assert.NotNull(marked.ReminderSentAt);

            var memberNotifs = (await fam.Member.From<AppNotification>().Get()).Models!;
            Assert.Contains(memberNotifs, n => n.Type == "family_deletion"
                && n.RecipientProfileId == fam.MemberProfile.Id
                && n.Message.Contains("excluída definitivamente em"));

            // Second run: already sent → nothing due for this request.
            var again = await fx.Service.Rpc("family_deletion_reminders_due", new Dictionary<string, object>());
            Assert.DoesNotContain($"\"request_id\":{untouched.Id}", (again.Content ?? string.Empty).Replace(" ", ""));
        }

        [Fact] // Past the window: the family is fully purged and the cron gets
               // every member's auth uid + REAL e-mail + the family name.
        public async Task PurgeExpiredFamilyDeletions_RemovesFamily_ReturnsUidsAndEmails()
        {
            var fam = await fx.CreateFamilyAsync("fdel-purge");
            var familyName = (await fx.Service.From<Family>()
                .Where(f => f.Id == fam.FamilyId).Get()).Models!.Single().Name;

            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_family_deletion", new Dictionary<string, object>());

            await fx.Service.From<FamilyDeletionRequest>()
                .Where(r => r.FamilyId == fam.FamilyId)
                .Set(r => r.ScheduledFor, DateTime.UtcNow.AddDays(-1))
                .Update();

            var result = await fx.Service.Rpc("purge_expired_family_deletions", new Dictionary<string, object>());
            var content = result.Content ?? string.Empty;
            Assert.Contains(fam.AdminProfile.UserId, content);
            Assert.Contains(fam.MemberProfile.UserId, content);
            Assert.Contains(fam.AdminProfile.Email, content);
            Assert.Contains(fam.MemberProfile.Email, content);
            Assert.Contains(familyName, content);

            // The family and every row of its data are gone.
            var families = (await fx.Service.From<Family>().Where(f => f.Id == fam.FamilyId).Get()).Models!;
            Assert.Empty(families);
            var profiles = (await fx.Service.From<Profile>().Where(p => p.FamilyId == fam.FamilyId).Get()).Models!;
            Assert.Empty(profiles);
        }
    }
}
