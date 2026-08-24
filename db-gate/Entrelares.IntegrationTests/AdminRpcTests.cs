using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // Suite D — the SECURITY DEFINER RPCs and onboarding rules: admin
    // invariants (F-14), role management (F-27) and invitation single-use
    // (F-15/V009). All enforced server-side.
    [Collection("e2e-family")]
    public class AdminRpcTests(E2EFamilyFixture fx)
    {
        private static async Task AssertRejectedAsync(string expectedMessagePart, Func<Task> action)
        {
            var ex = await Assert.ThrowsAnyAsync<Exception>(action);
            Assert.Contains(expectedMessagePart, ex.Message);
        }

        [Fact] // F-14 invariant: every family keeps at least one admin.
        public async Task LastAdmin_CannotBeDemoted()
        {
            // S-10: the RPC now demands an elevation BEFORE the invariant runs.
            await fx.ElevateAsync(fx.FounderProfile);

            await AssertRejectedAsync("pelo menos uma pessoa administradora",
                () => fx.Founder.Rpc("set_member_admin", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.FounderProfile.Id,
                    ["p_is_admin"] = false
                }));
        }

        [Fact] // F-27: role changes are admin-only.
        public async Task NonAdmin_CannotChangeRoles()
        {
            await AssertRejectedAsync("Somente administradores",
                () => fx.Member.Rpc("set_member_role", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.FounderProfile.Id,
                    ["p_role_id"] = fx.Roles.First().Id
                }));
        }

        [Fact] // F-27: the role must exist in the catalog table.
        public async Task InvalidRole_IsRejected()
        {
            await AssertRejectedAsync("Papel inválido",
                () => fx.Founder.Rpc("set_member_role", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_role_id"] = 999_999
                }));
        }

        [Fact] // F-27 happy path: admin changes a member's role (and restores it).
        public async Task Admin_ChangesMemberRole_AndBack()
        {
            var aunt = fx.Roles.First(r => r.RoleName.Equals("aunt", StringComparison.OrdinalIgnoreCase));
            var original = fx.MemberProfile.RoleId;

            try
            {
                await fx.Founder.Rpc("set_member_role", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_role_id"] = aunt.Id
                });

                var refreshed = (await fx.Founder.From<Profile>().Get()).Models!
                    .Single(p => p.Id == fx.MemberProfile.Id);
                Assert.Equal(aunt.Id, refreshed.RoleId);
            }
            finally
            {
                await fx.Founder.Rpc("set_member_role", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_role_id"] = original
                });
            }
        }

        [Fact] // F-15/V009: an accepted invitation token cannot be used again.
        public async Task UsedInvitationToken_CannotOnboardAnotherUser()
        {
            using var admin = new AdminApi();
            await Assert.ThrowsAnyAsync<Exception>(() =>
                admin.CreateConfirmedUserAsync(fx.TestEmail("intruder"), fx.Password, new
                {
                    full_name = "E2E Intruder",
                    invite_token = fx.InviteToken
                }));
        }
    }
}
