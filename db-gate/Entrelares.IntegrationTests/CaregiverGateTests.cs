using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-37 — freemium gate: a free family includes TWO caregivers; the 3rd+ is
    // Premium (add-only + grandfather). Enforced in create_invitation (the
    // admin-facing primary guard). The handle_new_user backstop is identical
    // logic and, per the MultiCaregiverTests rationale, not worth extra GoTrue
    // users to re-prove. Grandfather is automatic: a fresh family is premium
    // during its 30-day trial, so the gate is exercised by forcing plan = free
    // (set_family_plan also clears the trial, so is_premium() turns false).
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class CaregiverGateTests(E2EFamilyFixture fx)
    {
        private long GrandmotherRoleId =>
            fx.Roles.Single(r => r.RoleName == "grandmother").Id;

        private Task SetPlanAsync(long familyId, string plan) =>
            fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = familyId,
                ["p_plan"] = plan
            });

        [Fact] // A free family (plan=free, no trial) is blocked at the 3rd caregiver;
               // upgrading to premium immediately unblocks the same invite.
        public async Task FreeFamily_BlockedAtThirdCaregiver_PremiumUnblocks()
        {
            // Throwaway family starts with 2 active members and is premium via its
            // 30-day trial — force it to real free (clears the trial too).
            var fam = await fx.CreateFamilyAsync("f37-free");
            await SetPlanAsync(fam.FamilyId, "free");

            // The 3rd invitation is refused with the premium upsell message.
            var ex = await Assert.ThrowsAnyAsync<Exception>(() =>
                E2EFamilyFixture.CreateInvitationAsync(fam.Admin, fx.TestEmail("f37-free-3rd"), GrandmotherRoleId));
            Assert.Contains("Premium", ex.Message);

            // Upgrading to premium lets the very same 3rd invitation through.
            await SetPlanAsync(fam.FamilyId, "premium");
            var token = await E2EFamilyFixture.CreateInvitationAsync(
                fam.Admin, fx.TestEmail("f37-free-3rd"), GrandmotherRoleId);
            Assert.False(string.IsNullOrWhiteSpace(token));
        }

        [Fact] // A family still inside its 30-day trial is premium, so the 3rd
               // caregiver invite is allowed without any upgrade (grandfather grace).
        public async Task TrialFamily_AllowsThirdCaregiver()
        {
            var fam = await fx.CreateFamilyAsync("f37-trial");

            var token = await E2EFamilyFixture.CreateInvitationAsync(
                fam.Admin, fx.TestEmail("f37-trial-3rd"), GrandmotherRoleId);
            Assert.False(string.IsNullOrWhiteSpace(token));
        }
    }
}
