using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-41 — custom per-family roles (Premium): creation is admin + Premium
    // (add-only: existing custom roles keep working on free, like F-37);
    // deletion is admin + unused-only; RLS and the RPC role checks keep one
    // family's custom rows invisible and unassignable to another. Grandfather
    // is automatic: a fresh family is premium via its 30-day trial, so the
    // gate is exercised by forcing plan = free (set_family_plan clears the
    // trial, making is_premium() false).
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class CustomRoleTests(E2EFamilyFixture fx)
    {
        private Task SetPlanAsync(long familyId, string plan) =>
            fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId,
                ["p_plan"] = plan
            });

        private static async Task<long> CreateCustomRoleAsync(Supabase.Client caller, string label, string? emoji = null)
        {
            var args = new Dictionary<string, object> { ["p_label"] = label };
            if (emoji is not null) args["p_emoji"] = emoji;
            var response = await caller.Rpc("create_custom_role", args);
            return long.Parse(response.Content ?? "0");
        }

        private static Task SetMemberRoleAsync(Supabase.Client caller, long profileId, long roleId) =>
            caller.Rpc("set_member_role", new Dictionary<string, object>
            {
                ["p_profile_id"] = profileId,
                ["p_role_id"] = roleId
            });

        private static Task DeleteCustomRoleAsync(Supabase.Client caller, long roleId) =>
            caller.Rpc("delete_custom_role", new Dictionary<string, object>
            {
                ["p_role_id"] = roleId
            });

        private static Task UpdateCustomRoleAsync(Supabase.Client caller, long roleId, string label, string? emoji = null)
        {
            var args = new Dictionary<string, object> { ["p_role_id"] = roleId, ["p_label"] = label };
            if (emoji is not null) args["p_emoji"] = emoji;
            return caller.Rpc("update_custom_role", args);
        }

        [Fact] // A free family (plan=free, no trial) cannot create custom roles;
               // upgrading to premium immediately unblocks the same creation.
        public async Task FreeFamily_CannotCreate_PremiumUnblocks()
        {
            var fam = await fx.CreateFamilyAsync("f41-free");
            await SetPlanAsync(fam.FamilyId, "free");

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                CreateCustomRoleAsync(fam.Admin, "E2E Papel Bloqueado"));
            Assert.Contains("Premium", ex.Message);

            await SetPlanAsync(fam.FamilyId, "premium");
            var roleId = await CreateCustomRoleAsync(fam.Admin, "E2E Papel Liberado", "🦉");
            Assert.True(roleId > 0);

            var roles = (await fam.Admin.From<Role>().Get()).Models ?? [];
            var created = roles.Single(r => r.Id == roleId);
            Assert.True(created.IsCustom);
            Assert.Equal("E2E Papel Liberado", created.RoleName);
            Assert.Equal("🦉", created.Emoji);
        }

        [Fact] // Creation is admin-only, even on a premium (trial) family.
        public async Task NonAdmin_CannotCreate()
        {
            var fam = await fx.CreateFamilyAsync("f41-nonadm");

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                CreateCustomRoleAsync(fam.Member, "E2E Papel do Membro"));
            Assert.Contains("administradores", ex.Message);
        }

        [Fact] // Another family neither SEES the custom role (RLS) nor can USE
               // its id in create_invitation / set_member_role (scope guards).
        public async Task CustomRole_InvisibleAndUnassignable_ToOtherFamily()
        {
            var roleId = await CreateCustomRoleAsync(fx.Founder, "E2E Papel Exclusivo A");

            // RLS: family B's roles read returns built-ins + B's own rows only.
            var rolesSeenByB = (await fx.FounderB.From<Role>().Get()).Models ?? [];
            Assert.DoesNotContain(rolesSeenByB, r => r.Id == roleId);

            // create_invitation: A's custom role id must not resolve for B.
            var inviteEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                E2EFamilyFixture.CreateInvitationAsync(fx.FounderB, fx.TestEmail("f41-cross"), roleId));
            Assert.Contains("Papel inválido", inviteEx.Message);

            // set_member_role: same guard on the member-edit path.
            var roleEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                SetMemberRoleAsync(fx.FounderB, fx.FounderBProfile.Id, roleId));
            Assert.Contains("Papel inválido", roleEx.Message);
        }

        [Fact] // Duplicates are refused case-insensitively — against the family's
               // own custom labels AND the built-in vocabulary.
        public async Task DuplicateLabel_Refused()
        {
            await CreateCustomRoleAsync(fx.Founder, "E2E Papel Duplicado");

            var dupEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                CreateCustomRoleAsync(fx.Founder, "e2e papel DUPLICADO"));
            Assert.Contains("Já existe", dupEx.Message);

            var builtinEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                CreateCustomRoleAsync(fx.Founder, "Avó"));
            Assert.Contains("Já existe", builtinEx.Message);
        }

        [Fact] // Deletion: blocked while a member uses the role; allowed once
               // unused; the row is actually gone afterwards.
        public async Task Delete_InUseBlocked_UnusedOk()
        {
            var fam = await fx.CreateFamilyAsync("f41-del");
            var roleId = await CreateCustomRoleAsync(fam.Admin, "E2E Papel Temporário");
            var originalRoleId = fam.MemberProfile.RoleId;

            await SetMemberRoleAsync(fam.Admin, fam.MemberProfile.Id, roleId);
            var inUseEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                DeleteCustomRoleAsync(fam.Admin, roleId));
            Assert.Contains("em uso", inUseEx.Message);

            await SetMemberRoleAsync(fam.Admin, fam.MemberProfile.Id, originalRoleId);
            await DeleteCustomRoleAsync(fam.Admin, roleId);

            var roles = (await fam.Admin.From<Role>().Get()).Models ?? [];
            Assert.DoesNotContain(roles, r => r.Id == roleId);
        }

        [Fact] // Built-ins and other families' rows are out of delete's reach.
        public async Task Delete_BuiltinOrForeignRole_Refused()
        {
            var builtinId = fx.Roles.Single(r => r.RoleName == "grandmother").Id;
            var builtinEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                DeleteCustomRoleAsync(fx.Founder, builtinId));
            Assert.Contains("não encontrado", builtinEx.Message);

            var roleId = await CreateCustomRoleAsync(fx.Founder, "E2E Papel Indelével");
            var foreignEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                DeleteCustomRoleAsync(fx.FounderB, roleId));
            Assert.Contains("não encontrado", foreignEx.Message);
        }

        [Fact] // QA2 — edit: a premium admin renames an IN-USE role (allowed by
               // design: role_id is the identity) and an omitted emoji clears it.
        public async Task Update_PremiumAdmin_RenamesInUseRole_AndClearsEmoji()
        {
            var fam = await fx.CreateFamilyAsync("f41-upd");
            var roleId = await CreateCustomRoleAsync(fam.Admin, "E2E Papel Original", "🦉");
            await SetMemberRoleAsync(fam.Admin, fam.MemberProfile.Id, roleId);

            await UpdateCustomRoleAsync(fam.Admin, roleId, "E2E Papel Renomeado");

            var updated = ((await fam.Admin.From<Role>().Get()).Models ?? []).Single(r => r.Id == roleId);
            Assert.Equal("E2E Papel Renomeado", updated.RoleName);
            Assert.Null(updated.Emoji);

            // The member still holds the same role id — the label just changed.
            var member = (await fam.Admin.From<Profile>().Get()).Models!
                .Single(p => p.Id == fam.MemberProfile.Id);
            Assert.Equal(roleId, member.RoleId);
        }

        [Fact] // QA2 — editing is Premium (owner decision), unlike deletion.
        public async Task Update_FreeFamily_Refused()
        {
            var fam = await fx.CreateFamilyAsync("f41-updfree");
            var roleId = await CreateCustomRoleAsync(fam.Admin, "E2E Papel Congelado");
            await SetPlanAsync(fam.FamilyId, "free");

            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                UpdateCustomRoleAsync(fam.Admin, roleId, "E2E Papel Alterado"));
            Assert.Contains("Premium", ex.Message);
        }

        [Fact] // QA2 — rename dedup: colliding with a built-in label is refused;
               // built-ins and other families' rows are out of edit's reach.
        public async Task Update_DuplicateOrForeignRole_Refused()
        {
            var roleId = await CreateCustomRoleAsync(fx.Founder, "E2E Papel Editável");

            var dupEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                UpdateCustomRoleAsync(fx.Founder, roleId, "Avó"));
            Assert.Contains("Já existe", dupEx.Message);

            var foreignEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                UpdateCustomRoleAsync(fx.FounderB, roleId, "E2E Papel Roubado"));
            Assert.Contains("não encontrado", foreignEx.Message);

            var builtinId = fx.Roles.Single(r => r.RoleName == "grandmother").Id;
            var builtinEx = await Assert.ThrowsAnyAsync<Exception>(() =>
                UpdateCustomRoleAsync(fx.Founder, builtinId, "E2E Papel Sobrescrito"));
            Assert.Contains("não encontrado", builtinEx.Message);
        }

        [Fact] // Add-only grandfather: a family that drops to free KEEPS its
               // custom roles — visible and still assignable via set_member_role.
        public async Task FreeFamily_KeepsExistingCustomRoles()
        {
            var fam = await fx.CreateFamilyAsync("f41-keep");
            var roleId = await CreateCustomRoleAsync(fam.Admin, "E2E Papel Herdado");

            await SetPlanAsync(fam.FamilyId, "free");

            var roles = (await fam.Admin.From<Role>().Get()).Models ?? [];
            Assert.Contains(roles, r => r.Id == roleId);

            // Still assignable on free — the gate is on CREATION only.
            await SetMemberRoleAsync(fam.Admin, fam.MemberProfile.Id, roleId);
            var member = (await fam.Admin.From<Profile>().Get()).Models!
                .Single(p => p.Id == fam.MemberProfile.Id);
            Assert.Equal(roleId, member.RoleId);
        }
    }
}
