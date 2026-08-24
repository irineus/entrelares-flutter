using System.Text.Json;
using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-28 (PR1) — multi-caregiver membership rules that live in the database:
    // the 4-seat cap (members + open invitations), per-e-mail resend
    // revocation (inviting B must NOT kill A's pending invite), and a third
    // member joining through the real invitation flow.
    //
    // The acceptance-time cap in handle_new_user is defense-in-depth only:
    // because every open invitation reserves a seat at creation and expired/
    // revoked tokens cannot be accepted, the creation-time check already
    // guarantees the invariant — so it is not worth three extra GoTrue users.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class MultiCaregiverTests(E2EFamilyFixture fx)
    {
        private async Task<bool> TokenIsAliveAsync(string token)
        {
            var anon = await E2EFamilyFixture.NewClientAsync(TestEnv.AnonKey);
            var response = await anon.Rpc("get_invite_info", new Dictionary<string, object>
            {
                ["p_token"] = token
            });
            using var doc = JsonDocument.Parse(response.Content ?? "[]");
            return doc.RootElement.GetArrayLength() > 0;
        }

        // Family B accumulates open invitations from other tests in this
        // collection — start each scenario from a clean slate.
        private async Task RevokeAllOpenInvitationsAsync(long familyId, Supabase.Client admin)
        {
            var open = (await fx.Service.From<FamilyInvitation>()
                .Where(i => i.FamilyId == familyId)
                .Filter("accepted_at", Supabase.Postgrest.Constants.Operator.Is, "null")
                .Filter("revoked_at", Supabase.Postgrest.Constants.Operator.Is, "null")
                .Get()).Models ?? [];
            foreach (var inv in open)
            {
                await admin.Rpc("revoke_invitation", new Dictionary<string, object>
                {
                    ["p_invitation_id"] = inv.Id
                });
            }
        }

        [Fact] // A third caregiver joins family A through the real invite flow.
        public async Task ThirdMember_JoinsThroughInvitation()
        {
            var grandmother = fx.Roles.Single(r => r.RoleName == "grandmother");
            var third = await fx.EnsureThirdMemberAsync();

            var profiles = (await fx.Founder.From<Profile>().Get()).Models ?? [];
            Assert.Contains(profiles, p => p.Id == third.Id);
            Assert.Equal(grandmother.Id, third.RoleId);
            Assert.False(third.IsAdmin);
            Assert.Equal(fx.FamilyId, third.FamilyId);
        }

        [Fact] // Two invitations coexist; resending one revokes ONLY that e-mail's token.
        public async Task OpenInvitations_Coexist_AndResendIsPerEmail()
        {
            await RevokeAllOpenInvitationsAsync(fx.FamilyBId, fx.FounderB);
            var role = fx.Roles.First();
            var emailX = fx.TestEmail("multi-x");
            var emailY = fx.TestEmail("multi-y");

            var tokenX  = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, emailX, role.Id);
            var tokenY1 = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, emailY, role.Id);

            // Both invitations are open at the same time (impossible pre-F-28).
            Assert.True(await TokenIsAliveAsync(tokenX));
            Assert.True(await TokenIsAliveAsync(tokenY1));

            // Resend to Y: Y's old token dies, X's invitation is untouched.
            var tokenY2 = await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, emailY, role.Id);
            Assert.False(await TokenIsAliveAsync(tokenY1));
            Assert.True(await TokenIsAliveAsync(tokenY2));
            Assert.True(await TokenIsAliveAsync(tokenX));

            await RevokeAllOpenInvitationsAsync(fx.FamilyBId, fx.FounderB);
        }

        [Fact] // QA fix — a pending swap between two caregivers is VISIBLE to the
               // third (family-scoped SELECT): their calendar must freeze the day
               // too. The V002 requester/target-only policy hid it from observers.
        public async Task PendingSwap_IsVisibleToUninvolvedCaregiver()
        {
            var third = await fx.EnsureThirdMemberAsync();
            var day = fx.NextFutureDate();

            await fx.Founder.From<CareSchedule>().Insert(new CareSchedule
            {
                ScheduleDate = day,
                ScheduledParentId = fx.FounderProfile.Id
            });
            await fx.Member.From<SwapRequest>().Insert(new SwapRequest
            {
                ScheduleDate = day,
                RequestingProfileId = fx.MemberProfile.Id,
                TargetProfileId = fx.FounderProfile.Id,
                ProposedActualParentId = fx.MemberProfile.Id,
                Status = "pending",
                CreatedAt = DateTime.UtcNow,
                UpdatedAt = DateTime.UtcNow
            });

            var thirdClient = await fx.SignInAsync(third.Email);
            var seen = (await thirdClient.From<SwapRequest>()
                .Filter("schedule_date", Supabase.Postgrest.Constants.Operator.Equals, day.ToString("yyyy-MM-dd"))
                .Get()).Models ?? [];
            Assert.Contains(seen, r => r.Status == "pending");

            // Don't leak a frozen day into the rest of the collection.
            await fx.Service.From<SwapRequest>()
                .Filter("family_id", Supabase.Postgrest.Constants.Operator.Equals, fx.FamilyId.ToString())
                .Filter("schedule_date", Supabase.Postgrest.Constants.Operator.Equals, day.ToString("yyyy-MM-dd"))
                .Delete();
        }

        [Fact] // Seats = members + open invitations; the 5th seat is refused.
        public async Task SeatCap_BlocksInvitesBeyondFourSeats()
        {
            await RevokeAllOpenInvitationsAsync(fx.FamilyBId, fx.FounderB);
            var role = fx.Roles.First();

            var members = (await fx.FounderB.From<Profile>().Get()).Models!.Count;
            var freeSeats = 4 - members;
            for (var i = 0; i < freeSeats; i++)
                await E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, fx.TestEmail($"cap-{i}"), role.Id);

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, fx.TestEmail("cap-overflow"), role.Id));
            Assert.Contains("limite de 4", ex.Message);

            await RevokeAllOpenInvitationsAsync(fx.FamilyBId, fx.FounderB);
        }
    }
}
