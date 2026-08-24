using Entrelares.Models;

namespace Entrelares.IntegrationTests
{
    // F-32 — freemium foundation, DB rules:
    //   · set_family_plan is service_role ONLY — no client can self-upgrade.
    //   · new families default to free + a 30-day Premium trial; is_premium()
    //     is the single source of truth and mirrors that.
    //   · the premium_interest waitlist is family-scoped (RLS) and idempotent.
    [Collection("e2e-family")]
    [Trait("pack", "p1")]
    public class PremiumEntitlementTests(E2EFamilyFixture fx)
    {
        // ── No self-upgrade ──────────────────────────────────────────────────

        [Fact] // Even the family ADMIN cannot promote their own family: the RPC
               // is granted to service_role alone. Plan changes only ever come
               // from a trusted server context (billing, T-39).
        public async Task Admin_CannotSelfUpgradePlan()
        {
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Founder.Rpc("set_family_plan", new Dictionary<string, object>
                {
                    ["p_family_id"] = fx.FamilyId,
                    ["p_plan"] = "premium"
                }));

            // Defensive: the plan really did not change.
            var family = (await fx.Founder.From<Family>().Get()).Models!.Single();
            Assert.Equal("free", family.Plan);
        }

        [Fact] // A non-admin member is likewise denied.
        public async Task Member_CannotSelfUpgradePlan()
        {
            await Assert.ThrowsAnyAsync<Exception>(() =>
                fx.Member.Rpc("set_family_plan", new Dictionary<string, object>
                {
                    ["p_family_id"] = fx.FamilyId,
                    ["p_plan"] = "premium"
                }));
        }

        // ── Default trial + entitlement helper ───────────────────────────────

        [Fact] // A family created through the real onboarding path defaults to
               // free with a ~30-day trial; is_premium() agrees (trial ⇒ premium).
        public async Task NewFamily_IsFreeOnTrial_AndHelperAgrees()
        {
            var family = (await fx.Founder.From<Family>().Get()).Models!.Single();
            Assert.Equal("free", family.Plan);
            Assert.NotNull(family.TrialEndsAt);
            Assert.True(family.TrialEndsAt > DateTime.UtcNow.AddDays(25), "trial should be ~30 days out");
            Assert.True(family.TrialEndsAt < DateTime.UtcNow.AddDays(35), "trial should be ~30 days out");

            var isPremium = await fx.Founder.Rpc("is_premium", new Dictionary<string, object>());
            Assert.Contains("true", isPremium.Content ?? "");
        }

        // ── Service-role plan changes + trial clearing ───────────────────────

        [Fact] // service_role CAN set the plan (the billing path). Dropping to
               // free clears the trial so is_premium() becomes honest; going
               // premium flips it back. Runs on a throwaway family so the shared
               // one keeps its default state.
        public async Task ServiceRole_SetsPlan_AndHelperReflectsIt()
        {
            var fam = await fx.CreateFamilyAsync("f32plan");

            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = fam.FamilyId,
                ["p_plan"] = "free"
            });
            var afterFree = await fx.Service.Rpc("is_premium",
                new Dictionary<string, object> { ["p_family_id"] = fam.FamilyId });
            Assert.Contains("false", afterFree.Content ?? "");

            await fx.Service.Rpc("set_family_plan", new Dictionary<string, object>
            {
                ["p_family_id"] = fam.FamilyId,
                ["p_plan"] = "premium"
            });
            var afterPremium = await fx.Service.Rpc("is_premium",
                new Dictionary<string, object> { ["p_family_id"] = fam.FamilyId });
            Assert.Contains("true", afterPremium.Content ?? "");
        }

        // ── Waitlist ─────────────────────────────────────────────────────────

        [Fact] // Any member registers interest; the family reads its own row;
               // re-registering stays idempotent; another family never sees it.
        public async Task PremiumInterest_IsRecordedPerFamily_AndFamilyScoped()
        {
            await fx.Member.Rpc("register_premium_interest", new Dictionary<string, object>());

            var mine = (await fx.Founder.From<PremiumInterest>().Get()).Models ?? [];
            Assert.Single(mine);
            Assert.Equal(fx.FamilyId, mine[0].FamilyId);

            // Idempotent per family — a second registration refreshes, not appends.
            await fx.Founder.Rpc("register_premium_interest", new Dictionary<string, object>());
            Assert.Single((await fx.Founder.From<PremiumInterest>().Get()).Models ?? []);

            // Cross-family isolation: family B sees none of A's interest.
            Assert.Empty((await fx.FounderB.From<PremiumInterest>().Get()).Models ?? []);
        }
    }
}
