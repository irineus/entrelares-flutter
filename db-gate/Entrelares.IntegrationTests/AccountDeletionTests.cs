using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // S-11 (PR1) — individual account deletion (leave the family):
    //   · sudo-gated (ELEVATION_REQUIRED without a fresh password);
    //   · the only admin must name a successor (promoted before leaving);
    //   · the last active member's exit schedules the WHOLE family for removal;
    //   · leaving clears the member's FUTURE days, frees the seat, keeps the
    //     PAST (name preserved), and can be cancelled while a seat is free;
    //   · purge_expired_accounts scrubs the e-mail (member) or purges the whole
    //     family (last member) and returns the auth uid(s) for the cron.
    // Destructive scenarios run on throwaway families so the shared fixture is
    // never mutated.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class AccountDeletionTests(E2EFamilyFixture fx)
    {
        [Fact] // No elevation → the detectable ELEVATION_REQUIRED contract, no mutation.
        public async Task RequestAccountDeletion_WithoutElevation_IsRejected()
        {
            await fx.ClearElevationAsync(fx.MemberProfile);

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.Rpc("request_account_deletion", new Dictionary<string, object>()));
            Assert.Contains("ELEVATION_REQUIRED", ex.Message);
        }

        [Fact] // Only admin: leaving requires a successor, who is promoted first.
        public async Task RequestAccountDeletion_OnlyAdmin_RequiresSuccessor_ThenPromotes()
        {
            var fam = await fx.CreateFamilyAsync("succ");

            // Without a successor → rejected, no mutation.
            await fx.ElevateAsync(fam.AdminProfile);
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("request_account_deletion", new Dictionary<string, object>()));
            var stillHere = (await fam.Admin.From<Profile>().Get()).Models!
                .Single(p => p.Id == fam.AdminProfile.Id);
            Assert.Null(stillHere.LeftAt);

            // With a successor → the member is promoted and the admin leaves.
            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_account_deletion",
                new Dictionary<string, object> { ["p_new_admin_id"] = fam.MemberProfile.Id });

            var all = (await fam.Member.From<Profile>().Get()).Models!;
            Assert.True(all.Single(p => p.Id == fam.MemberProfile.Id).IsAdmin);   // successor promoted
            Assert.NotNull(all.Single(p => p.Id == fam.AdminProfile.Id).LeftAt);  // admin is leaving
        }

        [Fact] // Last member leaving → the whole family is purged after the grace.
        public async Task LastMember_Leaving_PurgesWholeFamily()
        {
            var fam = await fx.CreateFamilyAsync("lastm");

            // The member leaves first, leaving the admin as the sole active member.
            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            // The admin (now the last member) leaves — no successor needed.
            await fx.ElevateAsync(fam.AdminProfile);
            await fam.Admin.Rpc("request_account_deletion", new Dictionary<string, object>());

            // Backdate both grace periods and run the purge.
            await fx.Service.From<Profile>()
                .Where(p => p.FamilyId == fam.FamilyId)
                .Set(p => p.DeletionScheduledFor!, DateTime.UtcNow.AddDays(-1))
                .Update();

            var result = await fx.Service.Rpc("purge_expired_accounts", new Dictionary<string, object>());

            // The whole family is gone and both auth uids came back for the cron.
            var families = (await fx.Service.From<Family>().Where(f => f.Id == fam.FamilyId).Get()).Models!;
            Assert.Empty(families);
            Assert.Contains(fam.AdminProfile.UserId, result.Content ?? string.Empty);
            Assert.Contains(fam.MemberProfile.UserId, result.Content ?? string.Empty);
        }

        [Fact] // Full leave: future cleared, seat freed, then cancel restores.
        public async Task LeaveFamily_ClearsFuture_FreesSeat_AndCancelRestores()
        {
            var fam = await fx.CreateFamilyAsync("leave");

            // A future planned day AND today's day for the leaving member —
            // S-11 QA: today counts as future and must be cleared too.
            var futureDay = DateOnly.FromDateTime(DateTime.Today).AddDays(20);
            var todayDay  = DateOnly.FromDateTime(DateTime.Today);
            await fam.Admin.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = futureDay,
                ScheduledParentId = fam.MemberProfile.Id
            });
            await fam.Admin.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = todayDay,
                ScheduledParentId = fam.MemberProfile.Id
            });

            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            // Leaving state: left_at set, 30-day schedule, seat freed.
            var members = (await fam.Admin.From<Profile>().Get()).Models!;
            var leaver  = members.Single(p => p.Id == fam.MemberProfile.Id);
            Assert.NotNull(leaver.LeftAt);
            Assert.NotNull(leaver.DeletionScheduledFor);
            Assert.Equal(1, members.Count(p => p.IsActiveMember));   // only the admin holds a seat

            // Both the future day and today's day are gone.
            var days = (await fam.Admin.From<CareSchedule>().Get()).Models!;
            Assert.DoesNotContain(days, d => d.ScheduleDate == futureDay);
            Assert.DoesNotContain(days, d => d.ScheduleDate == todayDay);

            // The other member is notified in-app (transparency — e-mail is the
            // best-effort twin, dispatched from the client).
            var adminNotifs = (await fam.Admin.From<AppNotification>().Get()).Models!;
            Assert.Contains(adminNotifs, n => n.Type == "account_deletion"
                && n.RecipientProfileId == fam.AdminProfile.Id);

            // Cancel restores membership (a seat is still free).
            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("cancel_account_deletion", new Dictionary<string, object>());
            var restored = (await fam.Admin.From<Profile>().Get()).Models!.Single(p => p.Id == fam.MemberProfile.Id);
            Assert.Null(restored.LeftAt);
            Assert.True(restored.IsActiveMember);
        }

        [Fact] // S-11 QA color slots: sticky per person; a joiner takes the freed
               // slot; a returner whose color was taken gets the next free one.
        public async Task ColorSlots_Sticky_RecycledOnJoin_ReassignedOnReturn()
        {
            var fam = await fx.CreateFamilyAsync("slots");

            var members = (await fam.Admin.From<Profile>().Get()).Models!;
            Assert.Equal(1, members.Single(p => p.Id == fam.AdminProfile.Id).ColorSlot);
            Assert.Equal(2, members.Single(p => p.Id == fam.MemberProfile.Id).ColorSlot);

            // The member leaves (keeps their stored slot; admin unchanged).
            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            // A third person joins through the real invite flow → takes slot 2.
            using var adminApi = new AdminApi();
            var thirdEmail = fx.TestEmail("slots-3rd");
            var aunt = fx.Roles.First(r => r.RoleName.Equals("aunt", StringComparison.OrdinalIgnoreCase));
            var token = await E2EFamilyFixture.CreateInvitationAsync(fam.Admin, thirdEmail, aunt.Id);
            await adminApi.CreateConfirmedUserAsync(thirdEmail, fx.Password, new
            {
                full_name = "E2E Slots Third",
                invite_token = token
            });

            members = (await fam.Admin.From<Profile>().Get()).Models!;
            var third = members.Single(p => p.Email == thirdEmail);
            Assert.Equal(2, third.ColorSlot);                                        // freed color reused
            Assert.Equal(1, members.Single(p => p.Id == fam.AdminProfile.Id).ColorSlot); // untouched

            // The departed member returns — their old color is taken → gets 3.
            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("cancel_account_deletion", new Dictionary<string, object>());

            var returned = (await fam.Admin.From<Profile>().Get()).Models!
                .Single(p => p.Id == fam.MemberProfile.Id);
            Assert.True(returned.IsActiveMember);
            Assert.Equal(3, returned.ColorSlot);
        }

        [Fact] // Joining and returning both notify the other members in-app.
        public async Task Join_And_Return_NotifyOtherMembers()
        {
            // CreateFamilyAsync adds a member through the real invite flow, so the
            // admin must already have a member_joined notification.
            var fam = await fx.CreateFamilyAsync("notify");

            var adminNotifs = (await fam.Admin.From<AppNotification>().Get()).Models!;
            Assert.Contains(adminNotifs, n => n.Type == "member_joined"
                && n.RecipientProfileId == fam.AdminProfile.Id);

            // The member leaves and then returns → the admin is told they are back.
            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());
            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("cancel_account_deletion", new Dictionary<string, object>());

            var afterReturn = (await fam.Admin.From<AppNotification>().Get()).Models!;
            Assert.Contains(afterReturn, n => n.Type == "member_returned"
                && n.RecipientProfileId == fam.AdminProfile.Id);
        }

        [Fact] // A departed member is frozen: no profile edits, no day assignment.
        public async Task DepartedMember_IsFrozen_NoEditsNoAssignment()
        {
            var fam = await fx.CreateFamilyAsync("freeze");

            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            // Rename blocked.
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("update_member_name", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fam.MemberProfile.Id,
                    ["p_full_name"] = "Nome Novo"
                }));

            // Promote blocked (elevated, so it reaches the frozen-row guard).
            await fx.ElevateAsync(fam.AdminProfile);
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.Rpc("set_member_admin", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fam.MemberProfile.Id,
                    ["p_is_admin"] = true
                }));

            // Assigning a future day to the departed member is blocked.
            var futureDay = DateOnly.FromDateTime(DateTime.Today).AddDays(25);
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fam.Admin.From<CareSchedule>().Insert(new CareSchedule
                {
                    ScheduleDate = futureDay,
                    ScheduledParentId = fam.MemberProfile.Id
                }));

            // The member stayed a non-admin with the original name.
            var frozen = (await fam.Admin.From<Profile>().Get()).Models!
                .Single(p => p.Id == fam.MemberProfile.Id);
            Assert.False(frozen.IsAdmin);
            Assert.Equal(fam.MemberProfile.FullName, frozen.FullName);
        }

        [Fact] // Cross-family migration: the previous family surfaces only for a
               // departed member; an active member's e-mail yields nothing.
        public async Task DepartedMemberFamily_SurfacesPreviousFamily_ForLeavingMemberOnly()
        {
            var fam = await fx.CreateFamilyAsync("xfam-name");
            var familyName = (await fx.Service.From<Family>()
                .Where(f => f.Id == fam.FamilyId).Get()).Models!.Single().Name;

            // Active member → no migratable previous family.
            var active = await fx.Service.Rpc("departed_member_family",
                new Dictionary<string, object> { ["p_email"] = fam.MemberProfile.Email });
            Assert.DoesNotContain(familyName, active.Content ?? string.Empty);

            // Member leaves (admin stays) → the previous family is now surfaced.
            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            var departed = await fx.Service.Rpc("departed_member_family",
                new Dictionary<string, object> { ["p_email"] = fam.MemberProfile.Email });
            Assert.Contains(familyName, departed.Content ?? string.Empty);
        }

        [Fact] // Cross-family migration: purging a departed member on demand
               // tombstones them (others remain), keeps history, returns the uid.
        public async Task PurgeDepartedMemberByEmail_Tombstones_WhenOthersRemain_ReturnsUid()
        {
            var fam = await fx.CreateFamilyAsync("xfam-purge");
            var originalName = fam.MemberProfile.FullName;
            var uid = fam.MemberProfile.UserId;

            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            // On-demand migration purge (no grace backdating needed) — the admin
            // still holds a seat, so the member is tombstoned, not the family.
            var result = await fx.Service.Rpc("purge_departed_member_by_email",
                new Dictionary<string, object> { ["p_email"] = fam.MemberProfile.Email });
            Assert.Contains(uid, result.Content ?? string.Empty);

            var purged = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.MemberProfile.Id).Get()).Models!.Single();
            Assert.StartsWith("removido+", purged.Email);   // e-mail freed for the new family
            Assert.Equal(originalName, purged.FullName);     // name preserved (history)

            // The family and the admin survive.
            var admin = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.AdminProfile.Id).Get()).Models!.Single();
            Assert.True(admin.IsActiveMember);
        }

        [Fact] // Past grace → purge scrubs the e-mail, keeps the name, returns the uid.
        public async Task PurgeExpiredAccounts_ScrubsEmail_KeepsName_ReturnsUid()
        {
            var fam = await fx.CreateFamilyAsync("purge");
            var originalName = fam.MemberProfile.FullName;
            var uid = fam.MemberProfile.UserId;

            await fx.ElevateAsync(fam.MemberProfile);
            await fam.Member.Rpc("request_account_deletion", new Dictionary<string, object>());

            // Backdate the grace so the purge picks it up now.
            await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.MemberProfile.Id)
                .Set(p => p.DeletionScheduledFor!, DateTime.UtcNow.AddDays(-1))
                .Update();

            var result = await fx.Service.Rpc("purge_expired_accounts", new Dictionary<string, object>());
            Assert.Contains(uid, result.Content ?? string.Empty);

            var purged = (await fx.Service.From<Profile>()
                .Where(p => p.Id == fam.MemberProfile.Id).Get()).Models!.Single();
            Assert.StartsWith("removido+", purged.Email);           // e-mail scrubbed
            Assert.Equal(originalName, purged.FullName);            // name preserved (history)
        }
    }
}
