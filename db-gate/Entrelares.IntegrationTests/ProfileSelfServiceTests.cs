using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-16 — profile self-service rules at the database level: own-row name
    // edit works, other rows stay locked (RLS), role self-edit is blocked
    // (new guard), update_member_name is admin-only, and the auth.users →
    // profiles e-mail sync trigger fires on confirmed e-mail changes.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class ProfileSelfServiceTests(E2EFamilyFixture fx)
    {
        private async Task<Profile> ReloadAsync(long profileId) =>
            (await fx.Service.From<Profile>().Where(p => p.Id == profileId).Get()).Models!.Single();

        [Fact] // Own display name: a plain targeted update through the own-row policy.
        public async Task Member_UpdatesOwnName()
        {
            var original = fx.MemberProfile.FullName;
            try
            {
                await fx.Member.From<Profile>()
                    .Where(p => p.Id == fx.MemberProfile.Id)
                    .Set(p => p.FullName, "E2E Member Renamed")
                    .Update();

                Assert.Equal("E2E Member Renamed", (await ReloadAsync(fx.MemberProfile.Id)).FullName);
            }
            finally
            {
                await fx.Service.From<Profile>()
                    .Where(p => p.Id == fx.MemberProfile.Id)
                    .Set(p => p.FullName, original)
                    .Update();
            }
        }

        [Fact] // RLS: another member's row is untouchable directly (silent zero rows).
        public async Task Member_CannotUpdateAnotherProfileDirectly()
        {
            await fx.Member.From<Profile>()
                .Where(p => p.Id == fx.FounderProfile.Id)
                .Set(p => p.FullName, "hacked")
                .Update();

            Assert.Equal(fx.FounderProfile.FullName, (await ReloadAsync(fx.FounderProfile.Id)).FullName);
        }

        [Fact] // F-16 guard: the own-row policy is not a side door for role edits.
        public async Task NonAdmin_CannotChangeOwnRole_Directly()
        {
            var otherRole = fx.Roles.First(r => r.Id != fx.MemberProfile.RoleId);

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.From<Profile>()
                    .Where(p => p.Id == fx.MemberProfile.Id)
                    .Set(p => p.RoleId, otherRole.Id)
                    .Update());
            Assert.Contains("podem alterar papéis", ex.Message);
        }

        [Fact] // update_member_name: admin-only, with name validation.
        public async Task UpdateMemberName_IsAdminOnly_AndValidates()
        {
            // Non-admin blocked.
            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.Rpc("update_member_name", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.FounderProfile.Id,
                    ["p_full_name"] = "Novo Nome"
                }));
            Assert.Contains("Somente administradores", ex.Message);

            // Admin with a too-short name blocked.
            ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.Rpc("update_member_name", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_full_name"] = " x "
                }));
            Assert.Contains("entre 2 e 80", ex.Message);

            // Admin happy path (and restore).
            var original = fx.MemberProfile.FullName;
            try
            {
                await fx.Founder.Rpc("update_member_name", new Dictionary<string, object>
                {
                    ["p_profile_id"] = fx.MemberProfile.Id,
                    ["p_full_name"] = "Nome Corrigido"
                });
                Assert.Equal("Nome Corrigido", (await ReloadAsync(fx.MemberProfile.Id)).FullName);
            }
            finally
            {
                await fx.Service.From<Profile>()
                    .Where(p => p.Id == fx.MemberProfile.Id)
                    .Set(p => p.FullName, original)
                    .Update();
            }
        }

        [Fact] // The sync trigger: a confirmed auth e-mail change lands in profiles.email.
        public async Task ConfirmedEmailChange_SyncsProfilesEmail()
        {
            var userId = Guid.Parse(fx.MemberProfile.UserId);
            var originalEmail = fx.MemberProfile.Email;
            var newEmail = fx.TestEmail("member-renamed");

            using var admin = new AdminApi();
            try
            {
                await admin.UpdateUserEmailAsync(userId, newEmail);
                Assert.Equal(newEmail, (await ReloadAsync(fx.MemberProfile.Id)).Email);
            }
            finally
            {
                await admin.UpdateUserEmailAsync(userId, originalEmail);
            }
        }
    }
}
